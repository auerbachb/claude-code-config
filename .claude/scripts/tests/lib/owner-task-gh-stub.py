#!/usr/bin/env python3
"""Stateful fake `gh` for owner-task.test.sh (issue #2538).

Holds repos, issues and comments in $FAKE_STATE/db.json under a file lock, so
two concurrent owner-task.sh runs see each other's writes the way they would on
GitHub. Every write is appended to $FAKE_STATE/writes.log as "METHOD ENDPOINT".

Knobs (environment):
  FAKE_CURRENT_REPO   what `gh repo view` reports
  FAKE_FAIL_READ      a repo (owner/name) whose every GET fails
  FAKE_FAIL_SEARCH    when set, search/issues fails
  FAKE_SEARCH_INCOMPLETE  when set, search/issues succeeds but reports
                      incomplete_results: true
  FAKE_SLOW           seconds to sleep after an issue-list read (widens races)
  FAKE_DROP_LABELS    when set, issue creation silently drops the labels (as
                      GitHub does for a caller without push access)
  FAKE_PAGE_SIZE     list results a call WITHOUT --paginate sees (default all),
                      so a caller that forgets to paginate loses the rest
"""
import fcntl
import json
import os
import re
import subprocess
import sys
import time

STATE = os.environ["FAKE_STATE"]
DB = os.path.join(STATE, "db.json")
LOCK = os.path.join(STATE, "db.lock")


def fail(msg, code=1):
    sys.stderr.write("gh: %s\n" % msg)
    sys.exit(code)


def emit(obj, jq_expr):
    text = json.dumps(obj)
    if jq_expr is None:
        sys.stdout.write(text + "\n")
        return
    out = subprocess.run(["jq", "-r", jq_expr], input=text, capture_output=True, text=True)
    if out.returncode != 0:
        fail("jq failed: " + out.stderr.strip())
    sys.stdout.write(out.stdout)


def main(argv):
    if argv[:2] == ["repo", "view"]:
        repo = os.environ.get("FAKE_CURRENT_REPO", "")
        if not repo:
            fail("no git remotes found")
        print(repo)
        return
    if not argv or argv[0] != "api":
        fail("stub: unsupported command " + " ".join(argv), 99)

    method, endpoint, jq_expr, fields, paginate = "GET", None, None, [], False
    args = argv[1:]
    i = 0
    while i < len(args):
        a = args[i]
        if a == "-X":
            method = args[i + 1]; i += 2
        elif a in ("-f", "-F", "--raw-field", "--field"):
            fields.append(args[i + 1]); i += 2
        elif a == "--jq":
            jq_expr = args[i + 1]; i += 2
        elif a == "--paginate":
            paginate = True
            i += 1
        else:
            if endpoint is None:
                endpoint = a
            i += 1
    params = {}
    labels = []
    for f in fields:
        k, _, v = f.partition("=")
        if k == "labels[]":
            labels.append(v)
        else:
            params[k] = v
    path, _, query = endpoint.partition("?")

    with open(LOCK, "w") as lk:
        fcntl.flock(lk, fcntl.LOCK_EX)
        with open(DB) as fh:
            db = json.load(fh)
        result, write = handle(db, method, path, query, params, labels)
        if write:
            with open(DB + ".tmp", "w") as fh:
                json.dump(db, fh)
            os.replace(DB + ".tmp", DB)
            with open(os.path.join(STATE, "writes.log"), "a") as fh:
                fh.write("%s %s\n" % (method, path))
    page = int(os.environ.get("FAKE_PAGE_SIZE", "0") or 0)
    if page and not paginate and method == "GET":
        if isinstance(result, list):
            result = result[:page]
        elif isinstance(result, dict) and "items" in result:
            result = dict(result, items=result["items"][:page])
    if method == "GET" and path.endswith("/issues") and os.environ.get("FAKE_SLOW"):
        time.sleep(float(os.environ["FAKE_SLOW"]))
    emit(result, jq_expr)


def handle(db, method, path, query, params, labels):
    if path == "search/issues":
        if os.environ.get("FAKE_FAIL_SEARCH"):
            fail("HTTP 503: search unavailable")
        items = []
        for repo, issues in db["issues"].items():
            for iss in issues:
                if iss["state"] == "open" and "human-tasks" in [lab["name"] for lab in iss["labels"]]:
                    items.append(dict(iss, repository_url="https://api.github.com/repos/" + repo))
        return {"total_count": len(items), "items": items,
                "incomplete_results": bool(os.environ.get("FAKE_SEARCH_INCOMPLETE"))}, False

    m = re.match(r"^repos/([^/]+/[^/]+)(/.*)?$", path)
    if not m:
        fail("stub: unknown endpoint " + path, 99)
    repo, rest = m.group(1), m.group(2) or ""
    if repo not in db["repos"]:
        fail("HTTP 404: Not Found (repos/%s)" % repo)
    if method == "GET" and os.environ.get("FAKE_FAIL_READ") == repo:
        fail("HTTP 500: read failed for " + repo)
    issues = db["issues"].setdefault(repo, [])

    if rest == "" and method == "GET":
        vis = db["repos"][repo]
        return {"full_name": repo, "visibility": vis, "private": vis == "private"}, False
    if rest == "/labels" and method == "POST":
        return {"name": params.get("name")}, True
    if rest == "/issues" and method == "GET":
        want = re.search(r"labels=([^&]+)", query)
        out = [i for i in issues if i["state"] == "open"
               and (not want or want.group(1) in [lab["name"] for lab in i["labels"]])]
        return out, False
    if rest == "/issues" and method == "POST":
        db["next_issue"] += 1
        iss = {"number": db["next_issue"], "title": params["title"], "body": params.get("body", ""),
               "state": "open",
               "labels": [] if os.environ.get("FAKE_DROP_LABELS") else [{"name": n} for n in labels]}
        issues.append(iss)
        return iss, True
    m2 = re.match(r"^/issues/(\d+)$", rest)
    if m2 and method == "PATCH":
        for iss in issues:
            if iss["number"] == int(m2.group(1)):
                iss["state"] = params.get("state", iss["state"])
                return iss, True
        fail("HTTP 404: no issue")
    m2 = re.match(r"^/issues/(\d+)/comments$", rest)
    if m2:
        key = "%s#%s" % (repo, m2.group(1))
        lst = db["comments"].setdefault(key, [])
        if method == "GET":
            return lst, False
        if method == "POST":
            db["next_comment"] += 1
            c = {"id": db["next_comment"], "body": params["body"]}
            lst.append(c)
            return c, True
    m2 = re.match(r"^/issues/comments/(\d+)$", rest)
    if m2 and method == "PATCH":
        for key, lst in db["comments"].items():
            if key.startswith(repo + "#"):
                for c in lst:
                    if c["id"] == int(m2.group(1)):
                        c["body"] = params["body"]
                        return c, True
        fail("HTTP 404: no comment")
    fail("stub: unsupported %s %s" % (method, path), 99)


if __name__ == "__main__":
    main(sys.argv[1:])
