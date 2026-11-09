#!/usr/bin/env python3
"""Advisory infrastructure cost report. Billing settings are never written."""

import argparse
import datetime as dt
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import tempfile
import time
import urllib.parse
from decimal import Decimal, InvalidOperation

SCHEMA = "infra-cost-audit/v1"
SLUG = re.compile(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,99}")
REPO = re.compile(r"[A-Za-z0-9][A-Za-z0-9-]{0,38}/[A-Za-z0-9_.-]{1,100}")
PERIOD = re.compile(r"20[0-9]{2}-(?:0[1-9]|1[0-2])")
BUILD_NAMES = {"Build CPU Minutes", "Build Minutes"}
TOOLS = {
    "gh": {"GH_TOKEN", "GITHUB_TOKEN", "GH_CONFIG_DIR"},
    "vercel": {"VERCEL_TOKEN"},
    "railway": {"RAILWAY_TOKEN", "RAILWAY_API_TOKEN"},
}
SAFE_ENV = {"HOME", "LANG", "LC_ALL", "LC_CTYPE", "PATH", "HTTPS_PROXY", "HTTP_PROXY", "NO_PROXY",
            "https_proxy", "http_proxy", "no_proxy", "SSL_CERT_FILE", "SSL_CERT_DIR"}
MAX_OUTPUT = 8_000_000


class Unavailable(Exception):
    """A provider result or piece of evidence is not usable."""


def obj(value):
    if not isinstance(value, dict):
        raise Unavailable("invalid object")
    return value


def seq(value):
    if not isinstance(value, list):
        raise Unavailable("invalid array")
    return value


def exact(rows, predicate):
    matches = [x for x in seq(rows) if isinstance(x, dict) and predicate(x)]
    if len(matches) != 1:
        raise Unavailable("missing or ambiguous provider identity")
    return matches[0]


def num(value, *, positive=False):
    if isinstance(value, bool) or not isinstance(value, (int, float, str, Decimal)):
        raise Unavailable("missing numeric evidence")
    try:
        n = Decimal(str(value))
    except InvalidOperation as exc:
        raise Unavailable("invalid numeric evidence") from exc
    if not n.is_finite() or n < 0 or n > 10**15 or (positive and not n):
        raise Unavailable("invalid numeric evidence")
    return n


def date(value):
    if not isinstance(value, str):
        raise Unavailable("missing provider date")
    try:
        parsed = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError as exc:
        raise Unavailable("invalid provider date") from exc
    if parsed.tzinfo is None:
        raise Unavailable("provider date has no time zone")
    return parsed.astimezone(dt.timezone.utc)


def utc(value):
    return value.isoformat(timespec="seconds").replace("+00:00", "Z")


def current_month(now):
    return now.strftime("%Y-%m")


def unavailable(call, reason="not reported"):
    try:
        return {"status": "ok", "data": call()}
    except Unavailable as exc:
        return {"status": "unavailable", "reason": str(exc) or reason}


def private_json(path):
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        with os.fdopen(fd, "rb") as src:
            info = os.fstat(src.fileno())
            if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
                raise Unavailable("config or baseline must be a private, user-owned file")
            raw = src.read(MAX_OUTPUT + 1)
        if len(raw) > MAX_OUTPUT:
            raise Unavailable("config or baseline too large")
        return obj(json.loads(raw))
    except (OSError, ValueError) as exc:
        raise Unavailable("cannot read config or baseline") from exc


def slug(value):
    if not isinstance(value, str) or not SLUG.fullmatch(value) or value in {".", ".."}:
        raise Unavailable("invalid provider identity")
    return value


def config(value):
    c = obj(value)
    if c.get("schema") != SCHEMA:
        raise Unavailable("unsupported config schema")
    github = c.get("github")
    if github is not None:
        github = obj(github)
        slug(github.get("account"))
        if github.get("kind") not in {"user", "organization"}:
            raise Unavailable("invalid GitHub billing scope")
    vercel = c.get("vercel")
    if vercel is not None:
        vercel = obj(vercel)
        if "scope" not in vercel:
            raise Unavailable("Vercel scope must be explicit")
        if vercel["scope"] is not None:
            slug(vercel["scope"])
    railway = c.get("railway")
    if railway is not None:
        slug(obj(railway).get("workspace"))
    names = set()
    repos = seq(c.get("repositories"))
    if not repos or len(repos) > 40:
        raise Unavailable("configure between one and forty repositories")
    for row in repos:
        row = obj(row)
        name = row.get("repo")
        if not isinstance(name, str) or not REPO.fullmatch(name) or name.rsplit("/", 1)[-1] in {".", ".."} or name.lower() in names:
            raise Unavailable("invalid or duplicate repository")
        names.add(name.lower())
        for k in ("personal", "monorepo", "allow_filing"):
            if k in row and type(row[k]) is not bool:
                raise Unavailable("invalid repository flag")
        if row.get("vercel") is not None:
            slug(obj(row["vercel"]).get("id"))
            slug(row["vercel"].get("name"))
        if row.get("railway") is not None:
            slug(row["railway"])
        related = seq(row.get("related_issues", []))
        if any(type(n) is not int or n <= 0 for n in related):
            raise Unavailable("invalid related issue number")
    thresholds = obj(c.get("thresholds", {}))
    for k, default in (("preview_per_day", 6), ("preview_per_merge", 5), ("share_jump", "0.15")):
        value = num(thresholds.get(k, default), positive=True)
        if k == "share_jump" and value >= 1:
            raise Unavailable("share jump must be below one")
    tools = obj(c.get("tools", {}))
    if set(tools) - TOOLS.keys() or any(not isinstance(v, str) or not Path(v).is_absolute() for v in tools.values()):
        raise Unavailable("tool overrides must be absolute paths")
    return c


class Runner:
    def __init__(self, tools, cwd):
        self.paths, self.cwd = tools, cwd
        self.deadline = time.monotonic() + 180
        trusted = {"/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", str(Path.home() / ".local/bin")}
        self.path = [p for p in os.environ.get("PATH", os.defpath).split(os.pathsep) if p in trusted]

    def tool(self, name):
        candidates = [Path(self.paths[name])] if name in self.paths else [Path(p) / name for p in self.path]
        for path in candidates:
            try:
                path = path.resolve(strict=True)
                info = path.stat()
                if (stat.S_ISREG(info.st_mode) and info.st_uid in {0, os.getuid()}
                        and not info.st_mode & 0o022 and os.access(path, os.X_OK)):
                    return path
            except (OSError, RuntimeError):
                continue
        raise Unavailable(f"{name} CLI not available")

    def __call__(self, tool, *args, body=None):
        env = {k: v for k, v in os.environ.items() if k in SAFE_ENV | TOOLS[tool]}
        env.update(CI="1", DO_NOT_TRACK="1", GH_PROMPT_DISABLED="1", NO_COLOR="1",
                   PATH=os.pathsep.join(self.path) or os.defpath)
        if tool == "gh":
            env["GH_HOST"] = "github.com"
        remaining = self.deadline - time.monotonic()
        if remaining <= 0:
            raise Unavailable("audit provider deadline reached")
        try:
            r = subprocess.run([str(self.tool(tool)), *args], cwd=self.cwd, env=env,
                               input=body or "", capture_output=True, text=True, timeout=min(25, remaining))
        except (OSError, subprocess.SubprocessError, UnicodeError) as exc:
            raise Unavailable(f"{tool} request unavailable") from exc
        if r.returncode:
            err = (r.stderr + r.stdout).lower()
            label = next((status for status in (401, 403, 404, 429) if f"http {status}" in err), None)
            raise Unavailable(f"{tool} request failed" + (f" (HTTP {label})" if label else ""))
        if len(r.stdout) > MAX_OUTPUT:
            raise Unavailable(f"{tool} response exceeded limit")
        return r.stdout

    def json(self, tool, *args, body=None):
        try:
            return json.loads(self(tool, *args, body=body))
        except ValueError as exc:
            raise Unavailable(f"{tool} returned invalid JSON") from exc


def vercel_args(settings):
    scope = settings["scope"]
    return ("--scope", scope) if scope is not None else ()


def vercel_usage(run, settings):
    args = vercel_args(settings)
    try:
        data = obj(run.json("vercel", "billing", "usage", "--group-by", "project", "--json", *args))
    except Unavailable:
        # Older installed releases expose the same grouped read as "usage".
        data = obj(run.json("vercel", "usage", "--group-by", "project", "--format", "json", *args))
    period = obj(data.get("period"))
    start, end = date(period.get("from")), date(period.get("to"))
    if start >= end:
        raise Unavailable("Vercel returned an invalid usage period")
    groups = obj(data.get("groupBy"))
    if groups.get("dimension") != "project":
        raise Unavailable("Vercel response is not grouped by project")
    return data, seq(groups.get("data")), start, end


def vercel_project(run, settings, row):
    mapping = row["vercel"]
    response = obj(run.json("vercel", "api", f"/v9/projects/{mapping['id']}", "-X", "GET", *vercel_args(settings)))
    if response.get("id") != mapping["id"] or response.get("name") != mapping["name"]:
        raise Unavailable("Vercel project ID or name does not match")
    link = obj(response.get("link"))
    if link.get("type") != "github" or not all(isinstance(link.get(k), str) for k in ("org", "repo")):
        raise Unavailable("Vercel project has no verified GitHub link")
    if f"{link['org']}/{link['repo']}".lower() != row["repo"].lower():
        raise Unavailable("Vercel project is linked to a different repository")
    resources = response.get("resourceConfig")
    machine = resources.get("buildMachineType") if isinstance(resources, dict) else None
    if machine is None:
        machine = response.get("buildMachineType")
    if not isinstance(machine, str) or machine not in {"standard", "enhanced", "turbo"}:
        machine = None
    ignore = response.get("commandForIgnoringBuildStep")
    has_ignore = None
    if "commandForIgnoringBuildStep" in response and (ignore is None or isinstance(ignore, str)):
        has_ignore = bool(ignore and ignore.strip())
    return {"machine": machine, "dashboard_ignore_configured": has_ignore}


def vercel_metrics(usage, mapping, now):
    data, groups, start, end = usage
    group = exact(groups, lambda x: x.get("name") == mapping["name"])
    services = {}
    for service in seq(group.get("services")):
        service = obj(service)
        name = service.get("name")
        if not isinstance(name, str) or name not in BUILD_NAMES:
            continue
        if name in services:
            raise Unavailable("ambiguous Vercel build metric")
        unit = service.get("pricingUnit")
        if not isinstance(unit, str) or not unit:
            raise Unavailable("Vercel build metric has no unit")
        quantity = num(service.get("pricingQuantity"))
        services[name] = {"minutes": quantity, "hours": quantity / 60}
        if unit in {"USD", "MIU"}:
            services[name]["provider_billed_amount"] = {"amount": num(service.get("billedCost")), "unit": unit}
    unit = data.get("pricingUnit")
    costs = {"status": "unavailable", "reason": "Vercel cost currency not reported"}
    if isinstance(unit, str) and unit in {"USD", "MIU"}:
        total = num(obj(data.get("totals")).get("billedCost"))
        project = num(obj(group.get("totals")).get("billedCost"))
        if project <= total:
            costs = {"status": "ok", "data": {"amount": project, "unit": unit,
                                              "share": (project / total if total else None)}}
    return {"from": utc(start), "to": utc(end), "observed_to": utc(min(now, end)),
            "build_metrics": services, "provider_billed_cost": costs}


def preview_count(run, settings, project_id, start, end):
    args = vercel_args(settings)
    base = {"projectId": project_id, "target": "preview", "limit": 100,
            "since": int(start.timestamp() * 1000), "until": int(end.timestamp() * 1000)}
    next_page = None
    seen = set()
    for _ in range(25):
        params = {**base}
        if next_page is not None:
            params["until"] = next_page
        path = "/v7/deployments?" + urllib.parse.urlencode(params)
        response = obj(run.json("vercel", "api", path, "-X", "GET", *args))
        for row in seq(response.get("deployments")):
            row = obj(row)
            if "target" not in row or row["target"] not in (None, "preview"):
                raise Unavailable("Vercel returned a non-preview deployment")
            deployment_id = row.get("uid")
            if not isinstance(deployment_id, str) or not deployment_id:
                raise Unavailable("Vercel deployment ID unavailable")
            seen.add(deployment_id)
        following = obj(response.get("pagination")).get("next")
        if following is None:
            return len(seen)
        if type(following) is not int or following >= params["until"] or following < base["since"]:
            raise Unavailable("invalid Vercel deployment cursor")
        next_page = following
    raise Unavailable("Vercel deployment pagination limit reached")


def gh_read(run, path, params=None):
    path += ("?" + urllib.parse.urlencode(params)) if params else ""
    return run.json("gh", "api", "--method", "GET", "-H", "X-GitHub-Api-Version: 2026-03-10", path)


def merge_count(run, repo, start, end):
    d = obj(run.json("gh", "repo", "view", repo, "--json", "nameWithOwner,defaultBranchRef"))
    if str(d.get("nameWithOwner", "")).lower() != repo.lower():
        raise Unavailable("GitHub repository identity not verified")
    branch = obj(d.get("defaultBranchRef")).get("name")
    if not isinstance(branch, str) or not re.fullmatch(r"[A-Za-z0-9_./-]{1,150}", branch):
        raise Unavailable("GitHub default branch unavailable")
    search = obj(gh_read(run, "search/issues",
                         {"q": f"repo:{repo} is:pr is:merged base:{branch} merged:{utc(start)}..{utc(end)}",
                          "per_page": 1}))
    count = search.get("total_count")
    if search.get("incomplete_results") is not False or type(count) is not int or count < 0:
        raise Unavailable("GitHub merge count incomplete")
    return count


def github_billing(run, settings, month):
    who = "users" if settings["kind"] == "user" else "organizations"
    year, m = month.split("-")
    result = obj(gh_read(run, f"{who}/{settings['account']}/settings/billing/usage",
                         {"year": int(year), "month": int(m)}))
    return seq(result.get("usageItems"))


def project_share(project, rows, field):
    try:
        total = sum((num(obj(x).get(field)) for x in rows), Decimal(0))
    except Unavailable:
        return None
    if not total or project > total:
        return None
    return {"unit": "USD", "share": project / total}


def github_metrics(rows, name):
    all_minutes = [x for x in rows if isinstance(x, dict)
                   and str(x.get("product", "")).lower() == "actions"
                   and str(x.get("unitType", "")).lower() == "minutes"]
    minutes = [x for x in all_minutes if str(x.get("repositoryName", "")).lower() == name.lower()]
    if not minutes:
        raise Unavailable("no GitHub billed Actions minute rows reported for this repository")
    amount = sum((num(x.get("netAmount")) for x in minutes), Decimal(0))
    return {"actions_minutes": sum((num(x.get("quantity")) for x in minutes), Decimal(0)),
            "actions_net_amount_usd": amount, "cost_share": project_share(amount, all_minutes, "netAmount")}


def railway_usage(run, settings, month, now):
    period = "current" if month == current_month(now) else month
    d = obj(run.json("railway", "usage", "projects", "--workspace", settings["workspace"], "--period", period, "--json"))
    workspace = obj(d.get("workspace"))
    if settings["workspace"] not in (workspace.get("id"), workspace.get("name")):
        raise Unavailable("Railway workspace identity does not match")
    return seq(d.get("projects"))


def railway_metrics(rows, project):
    group = exact(rows, lambda x: project in (x.get("id"), x.get("name")))
    amount = num(group.get("currentUsageDollars"))
    return {"project_current_usage_usd": amount,
            "cost_share": project_share(amount, rows, "currentUsageDollars")}


def configured(settings, call):
    if settings is None:
        return {"status": "unavailable", "reason": "provider scope not configured"}
    return unavailable(call)


def fingerprint(provider, identity):
    if not isinstance(identity, str) or not identity:
        return None
    return hashlib.sha256((provider + ":" + identity).encode()).hexdigest()


def comparable_cost(evidence, provider):
    metric = obj(evidence.get({"vercel": "vercel_usage", "github": "github_actions", "railway": "railway"}[provider], {}))
    if metric.get("status") != "ok":
        return None
    data = obj(metric.get("data"))
    if provider != "vercel":
        return data.get("cost_share")
    cost = obj(data.get("provider_billed_cost"))
    return cost.get("data") if cost.get("status") == "ok" else None


def baseline_share(baseline, provider, scope, repo, cost, current_at):
    if not baseline or not scope or obj(baseline.get("provider_scopes", {})).get(provider) != scope:
        return None
    if baseline.get("schema") != SCHEMA or date(baseline.get("observed_at")) >= current_at:
        return None
    previous = [x for x in seq(baseline.get("repositories")) if isinstance(x, dict) and x.get("repo") == repo]
    if len(previous) != 1:
        return None
    old = comparable_cost(previous[0], provider)
    if not isinstance(old, dict) or old.get("unit") != cost.get("unit") or old.get("share") is None:
        return None
    prev = num(old["share"])
    return prev if prev <= 1 else None


def findings(row, evidence, limits, baseline, scopes, now):
    result = []
    settings = evidence["vercel_settings"]
    if settings["status"] == "ok":
        machine = settings["data"]["machine"]
        if row.get("personal") and machine in {"turbo", "enhanced"}:
            result.append({"code": "vercel_premium_machine", "machine": machine})
        if row.get("monorepo") and settings["data"]["dashboard_ignore_configured"] is False:
            result.append({"code": "vercel_dashboard_ignore_missing"})
    activity = evidence["preview_activity"]
    if activity["status"] == "ok":
        data = activity["data"]
        count, merges, days = data["preview_deployments"], data["merged_prs"], data["days"]
        if (count / days >= num(limits.get("preview_per_day", 6))
                and Decimal(count) / max(1, merges) >= num(limits.get("preview_per_merge", 5))):
            result.append({"code": "vercel_preview_volume", **data})
    for provider, scope in scopes.items():
        cost = comparable_cost(evidence, provider)
        if not isinstance(cost, dict) or cost.get("share") is None:
            continue
        try:
            old_share = baseline_share(baseline, provider, scope, row["repo"], cost, now)
        except Unavailable:
            old_share = None
        if old_share is not None and cost["share"] - old_share >= num(limits.get("share_jump", "0.15")):
            result.append({"code": f"{provider}_cost_share_jump", "share": cost["share"], "baseline_share": old_share})
    return result


def activities(run, settings, row, usage, now):
    start, end = usage[2], min(usage[3], now)
    seconds = (end - start).total_seconds()
    if seconds < 86400:
        raise Unavailable("preview comparison requires at least a full day")
    count = preview_count(run, settings, row["vercel"]["id"], start, end)
    merges = merge_count(run, row["repo"], start, end)
    return {"preview_deployments": count, "merged_prs": merges,
            "days": Decimal(str(seconds)) / 86400, "from": utc(start), "to": utc(end)}


def audit(run, cfg, month, now, baseline, file_issues):
    vercel, github, railway = (cfg.get(k) for k in ("vercel", "github", "railway"))
    live_month = month == current_month(now)
    vu = (configured(vercel, lambda: vercel_usage(run, vercel)) if live_month else
          {"status": "unavailable", "reason": "Vercel collector currently reads its current billing period"})
    gb = configured(github, lambda: github_billing(run, github, month))
    rw = configured(railway, lambda: railway_usage(run, railway, month, now))
    scopes = {
        "vercel": fingerprint("vercel", vu["data"][0].get("context")) if vu["status"] == "ok" else None,
        "github": fingerprint("github", github["kind"] + ":" + github["account"]) if gb["status"] == "ok" else None,
        "railway": fingerprint("railway", railway["workspace"]) if rw["status"] == "ok" else None,
    }
    report = {"schema": SCHEMA, "observed_at": utc(now), "github_railway_month": month,
              "provider_scopes": scopes, "filing_enabled": file_issues, "repositories": []}
    for row in cfg["repositories"]:
        name = row["repo"]
        out = {"repo": name}
        settings = configured(vercel if row.get("vercel") else None, lambda: vercel_project(run, vercel, row))
        out["vercel_settings"] = settings
        if settings["status"] != "ok":
            out["vercel_usage"] = out["preview_activity"] = settings
        elif vu["status"] != "ok":
            out["vercel_usage"] = out["preview_activity"] = vu
        else:
            out["vercel_usage"] = unavailable(lambda: vercel_metrics(vu["data"], row["vercel"], now))
            out["preview_activity"] = unavailable(lambda: activities(run, vercel, row, vu["data"], now))
        out["github_actions"] = (unavailable(lambda: github_metrics(gb["data"], name))
                                 if gb["status"] == "ok" else gb)
        out["railway"] = (unavailable(lambda: railway_metrics(rw["data"], row["railway"]))
                          if rw["status"] == "ok" and row.get("railway") else
                          {"status": "unavailable", "reason": "Railway project not configured"}
                          if not row.get("railway") else rw)
        out["findings"] = findings(row, out, cfg.get("thresholds", {}), baseline, scopes, now)
        out["filing"] = (unavailable(lambda: issue_plan(run, row, out["findings"], file_issues))
                         if out["findings"] else {"status": "not_needed"})
        report["repositories"].append(out)
    return report


MARKER = "<!-- infra-cost-audit:v1 -->"


def issue_body(items):
    lines = [MARKER, "", "## Infrastructure cost findings", ""]
    for x in items:
        code = x["code"]
        if code == "vercel_premium_machine":
            lines.append(f"- Vercel reports the **{x['machine']}** build machine. Review whether this project needs it.")
        elif code == "vercel_dashboard_ignore_missing":
            lines.append("- The Vercel dashboard's ignored build step is empty. Check for a repository override before configuring a path filter.")
        elif code == "vercel_preview_volume":
            lines.append(f"- Vercel reported {x['preview_deployments']} preview deployments and GitHub reported {x['merged_prs']} merged PRs from {x['from']} to {x['to']}. Review preview triggers.")
        elif code.endswith("_cost_share_jump"):
            label = {"vercel": "Vercel billed cost", "github": "GitHub Actions net minute charges",
                     "railway": "Railway project usage"}[code.split("_", 1)[0]]
            lines.append(f"- This project's share of {label} is {x['share']:.1%}, versus {x['baseline_share']:.1%} in the saved baseline. Review the provider usage breakdown.")
    lines += ["", "Provider observations only. The audit did not change a setting."]
    return "\n".join(lines) + "\n"


def issue_plan(run, row, items, apply):
    name = row["repo"]
    title = "Review infrastructure cost findings"
    body = issue_body(items)
    if apply and not row.get("allow_filing"):
        return {"decision": "filing_not_allowed_for_repo"}
    repo = obj(run.json("gh", "repo", "view", name, "--json", "nameWithOwner,isPrivate"))
    if str(repo.get("nameWithOwner", "")).lower() != name.lower():
        raise Unavailable("cannot verify the GitHub filing destination")
    if repo.get("isPrivate") is not True:
        return {"decision": "private_repo_required"}
    issues = seq(run.json("gh", "issue", "list", "--repo", name, "--state", "open", "--limit", "100",
                          "--json", "number,title,body"))
    if len(issues) >= 100:
        raise Unavailable("open issue dedup sample is incomplete")
    existing = []
    related = set(row.get("related_issues", []))
    for issue in issues:
        issue = obj(issue)
        number = issue.get("number")
        if type(number) is not int or number <= 0:
            raise Unavailable("invalid issue in dedup sample")
        ititle, ibody = issue.get("title"), issue.get("body")
        if not isinstance(ititle, str) or not isinstance(ibody, str):
            raise Unavailable("cannot inspect an open issue for dedup")
        current = ititle.lower()
        related_title = ("infrastructure cost" in current or "infra cost audit" in current or
                         ("vercel" in current and any(x in current for x in
                          ("turbo", "ignored build", "build cost", "build minutes", "preview builds"))) or
                         (("railway" in current or "github actions" in current) and
                          any(x in current for x in ("spend", "billing", "cost"))))
        if number in related or MARKER in ibody or related_title:
            existing.append(number)
    if existing:
        return {"decision": "existing_open_issue", "numbers": sorted(set(existing))}
    if not apply:
        return {"decision": "preview", "title": title, "body": body}
    try:
        response = obj(run.json("gh", "api", "--method", "POST", f"repos/{name}/issues", "--input", "-",
                                body=json.dumps({"title": title, "body": body})))
    except Unavailable as exc:
        raise Unavailable("filing outcome unconfirmed; inspect GitHub before retrying") from exc
    number, url = response.get("number"), response.get("html_url")
    if (type(number) is not int or number <= 0 or not isinstance(url, str)
            or url.lower() != f"https://github.com/{name}/issues/{number}".lower()
            or response.get("body") != body):
        raise Unavailable("created issue could not be confirmed; inspect GitHub before retrying")
    return {"decision": "filed", "number": number, "url": url}


def write_snapshot(path, output):
    try:
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as dst:
            dst.write(output)
    except OSError as exc:
        raise Unavailable("could not write a new private snapshot") from exc


def lock_filing(config_path):
    path = config_path.with_name(config_path.name + ".filing.lock")
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600)
    lock = os.fdopen(fd, "w")
    try:
        info = os.fstat(lock.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
            raise Unavailable("filing lock is not private")
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        return lock
    except (OSError, Unavailable):
        lock.close()
        raise


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--config", type=Path, required=True, help="private configuration file")
    p.add_argument("--month", help="GitHub and Railway usage month (YYYY-MM); default is current UTC month")
    p.add_argument("--baseline", type=Path, help="previous private snapshot")
    p.add_argument("--snapshot", type=Path, help="save a new private report (will not overwrite)")
    p.add_argument("--file-issues", action="store_true", help="allow filing in explicitly configured private repos")
    args = p.parse_args(argv)
    lock = None
    try:
        now = dt.datetime.now(dt.timezone.utc)
        month = args.month or current_month(now)
        if not PERIOD.fullmatch(month) or month > current_month(now):
            raise Unavailable("month must be YYYY-MM and not in the future")
        cfg = config(private_json(args.config))
        baseline = private_json(args.baseline) if args.baseline else None
        if args.snapshot and (args.snapshot.exists() or args.snapshot.is_symlink()):
            raise Unavailable("snapshot already exists")
        if args.file_issues:
            lock = lock_filing(args.config)
        with tempfile.TemporaryDirectory(prefix="infra-cost-audit-") as tmp:
            report = audit(Runner(cfg.get("tools", {}), tmp), cfg, month, now, baseline, args.file_issues)
        output = json.dumps(report, indent=2, default=str) + "\n"
        if args.snapshot:
            write_snapshot(args.snapshot, output)
        sys.stdout.write(output)
        return 0
    except (OSError, Unavailable, RecursionError) as exc:
        message = str(exc) if isinstance(exc, Unavailable) else "local audit unavailable"
        print(f"infra-cost-audit: {message}", file=sys.stderr)
        return 2
    finally:
        if lock:
            lock.close()


if __name__ == "__main__":
    raise SystemExit(main())
