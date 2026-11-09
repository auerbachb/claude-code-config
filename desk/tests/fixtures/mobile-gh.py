#!/usr/bin/env python3
"""Tiny local GitHub transport fixture; never performs network calls."""
import json
import os
from pathlib import Path
import sys
from urllib.parse import parse_qs, urlsplit

state = Path(os.environ["MOBILE_GH_STATE"])
d = json.loads(state.read_text())
argv = sys.argv[1:]
assert argv[:4] == ["api", "--hostname", "github.com", "--method"]
method, endpoint = argv[4:6]
parsed = urlsplit(endpoint)
path = parsed.path
owner = {"id": 77, "type": "User"}
root = "/repos/owner/mobile"
data = json.load(sys.stdin) if method != "GET" else None
if method == "GET" and path == root:
    out = {"id": d.get("repo_id", 101), "full_name": "owner/mobile", "private": d["private"],
           "visibility": "private" if d["private"] else "public", "has_issues": True,
           "archived": False, "permissions": {"admin": True}}
elif method == "GET" and path == "/user":
    out = owner
elif method == "GET" and path == root + "/issues":
    out = [x for x in d["issues"] if x["state"] == "open"]
elif method == "GET" and path.startswith(root + "/issues/") and path.endswith("/comments"):
    out = d.get("comments", {}).get(path.split("/")[-2], [])
elif method == "POST" and path == root + "/issues":
    assert d["private"]
    number = 1 + max((x["number"] for x in d["issues"]), default=0)
    out = dict(data, state="open", number=number, user=owner, created_at="2026-11-09T20:00:00Z")
    d["issues"].append(out)
    d["writes"].append(["create", number])
elif method == "PATCH" and path.startswith(root + "/issues/"):
    assert d["private"] and data == {"state": "closed"}
    number = int(path.rsplit("/", 1)[-1])
    out = next(x for x in d["issues"] if x["number"] == number)
    out["state"] = "closed"
    d["writes"].append(["close", number])
else:
    raise AssertionError((method, path))
if method == "GET" and isinstance(out, list) and parse_qs(parsed.query).get("page") != ["1"]:
    out = []
state.write_text(json.dumps(d))
print(json.dumps(out))
