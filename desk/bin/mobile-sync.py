#!/usr/bin/env python3
"""Opt-in projection of the desk queue to a pinned private GitHub inbox."""

import argparse
import datetime as dt
import fcntl
import hashlib
import hmac
import html
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import time
import unicodedata

DESK_BIN = Path(__file__).resolve().parent
ITEM = re.compile(r"[DR]-[1-9][0-9]*")
REPO = re.compile(r"[A-Za-z0-9][A-Za-z0-9-]{0,38}/[A-Za-z0-9_.-]{1,100}")
VERSION = re.compile(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.]+(?:Z|[+-][0-9:]+)")
MARKER = re.compile(
    r"\A<!-- desk-mobile:v1 id=([DR]-[1-9][0-9]*) version=(\S+) sig=([a-f0-9]{64}) -->\n"
)
LINK = re.compile(
    r"(?<![\w+.-])(?:[a-z][a-z0-9+.-]*://|mailto:|tel:)[^\s<>()\[\]{}\"']+"
    r"|(?<![\w.-])(?:[\w.+-]+@)?(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+"
    r"[a-z]{2,63}(?:[:/?#][^\s<>()\[\]{}\"']+)?(?![\w.-])",
    re.IGNORECASE,
)
JOINERS = "\u200c\u200d"
STRIP_JOINERS = str.maketrans("", "", JOINERS)
LOCAL_PATH = re.compile(r"""(?<![\w/])(?:[A-Za-z]:[\\/]|(?:~|\.\.?)?/)[^\s<>()\[\]{}"']+""")


class Unavailable(Exception):
    """The current pass cannot be proved safe."""


class DependencyFailed(Unavailable):
    def __init__(self, code):
        self.code = code
        super().__init__("mobile dependency failed")


def positive_id(value):
    return type(value) is int and 0 < value < 10**18


def timestamp(value):
    if not isinstance(value, str) or not VERSION.fullmatch(value):
        raise Unavailable("invalid timestamp")
    try:
        result = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError as exc:
        raise Unavailable("invalid timestamp") from exc
    if result.tzinfo is None:
        raise Unavailable("missing time zone")
    return result


def config_path():
    return Path(os.environ.get("DESK_MOBILE_CONFIG") or Path.home() / ".config/human-queue/mobile.json")


def load_config(path):
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except FileNotFoundError:
        return None
    with os.fdopen(fd, "rb") as f:
        info = os.fstat(f.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
            raise Unavailable("mobile config is not a private user file")
        raw = f.read(8193)
        if len(raw) > 8192:
            raise Unavailable("mobile config is too large")
    c = json.loads(raw)
    if (not isinstance(c, dict) or set(c) != {"repo", "repo_id", "operator_id", "signing_key"}
            or not isinstance(c["repo"], str) or not REPO.fullmatch(c["repo"])
            or not positive_id(c["repo_id"]) or not positive_id(c["operator_id"])
            or not isinstance(c["signing_key"], str)
            or not re.fullmatch(r"[a-f0-9]{64}", c["signing_key"])):
        raise Unavailable("invalid mobile config")
    return c


def trusted_gh():
    configured = os.environ.get("DESK_MOBILE_GH_BIN")
    candidates = [Path(configured)] if configured else [
        Path("/opt/homebrew/bin/gh"), Path("/usr/local/bin/gh"), Path("/usr/bin/gh"),
        Path.home() / ".local/bin/gh",
    ]
    for path in candidates:
        if not path.is_absolute():
            continue
        try:
            target = path.resolve(strict=True)
            info = target.stat()
            if (stat.S_ISREG(info.st_mode) and info.st_uid in {0, os.getuid()}
                    and not info.st_mode & 0o022 and os.access(target, os.X_OK)):
                return target
        except (OSError, RuntimeError):
            pass
    raise Unavailable("trusted gh not found")


class Runner:
    def __init__(self, limit=90):
        self.deadline = time.monotonic() + limit

    def call(self, argv, input_text=None, env=None):
        remaining = self.deadline - time.monotonic()
        if remaining <= 0:
            raise Unavailable("mobile pass deadline")
        try:
            r = subprocess.run(list(map(str, argv)), input=input_text, text=True,
                               capture_output=True, env=env, timeout=min(remaining, 12))
        except (OSError, subprocess.SubprocessError) as exc:
            raise Unavailable("mobile dependency unavailable") from exc
        if r.returncode:
            raise DependencyFailed(r.returncode)
        if len(r.stdout) > 2_000_000:
            raise Unavailable("mobile dependency returned too much data")
        return r.stdout


class Queue:
    def __init__(self, runner, session):
        self.runner, self.session = runner, session

    def call(self, *args, reply=None):
        return self.runner.call([DESK_BIN / "desk-cli.sh", *args], input_text=reply)

    def current(self):
        s = json.loads(self.call("control-status", "--json"))
        if not isinstance(s, dict) or s.get("session") != self.session:
            raise Unavailable("control moved")

    def open_items(self):
        return json.loads(self.call("mobile-reply", "snapshot", self.session))

    def apply(self, repo_id, comment_id, item_id, version, action, reply):
        try:
            return self.call("mobile-reply", "apply", self.session, repo_id, comment_id,
                             item_id, version, action, reply=reply).strip()
        except DependencyFailed as exc:
            if exc.code in {4, 5}:
                return "refused"
            raise

    def pending(self):
        return json.loads(self.call("mobile-reply", "pending", self.session))


class Github:
    def __init__(self, runner, config):
        self.runner, self.config = runner, config
        self.bin = trusted_gh()
        self.root = "/repos/" + config["repo"]
        self.env = dict(os.environ, GH_PROMPT_DISABLED="1")
        self.env.pop("HUMAN_QUEUE_DATABASE_URL", None)

    def api(self, method, endpoint, data=None):
        cmd = [self.bin, "api", "--hostname", "github.com", "--method", method, endpoint]
        if data is not None:
            cmd += ["--input", "-"]
        return json.loads(self.runner.call(cmd, input_text=None if data is None else json.dumps(data), env=self.env))

    def verify(self):
        c = self.config
        r = self.api("GET", self.root)
        actor = self.api("GET", "/user")
        if (not isinstance(r, dict) or r.get("id") != c["repo_id"]
                or not isinstance(r.get("full_name"), str) or r["full_name"].lower() != c["repo"].lower()
                or r.get("private") is not True or r.get("visibility") != "private"
                or r.get("has_issues") is not True or r.get("archived") is not False
                or not isinstance(r.get("permissions"), dict) or r["permissions"].get("admin") is not True
                or not isinstance(actor, dict) or actor.get("id") != c["operator_id"]
                or actor.get("type") != "User"):
            raise Unavailable("private inbox or operator does not match pinned identity")

    def pages(self, suffix):
        result = []
        for page in range(1, 5):
            sep = "&" if "?" in suffix else "?"
            batch = self.api("GET", self.root + suffix + f"{sep}per_page=100&page={page}")
            if not isinstance(batch, list) or len(batch) > 100 or not all(isinstance(x, dict) for x in batch):
                raise Unavailable("invalid GitHub list")
            result.extend(batch)
            if len(batch) < 100:
                return result
        raise Unavailable("GitHub pagination bound reached")

    def owner(self, obj):
        user = obj.get("user")
        return isinstance(user, dict) and user.get("id") == self.config["operator_id"] and user.get("type") == "User"

    def close(self, number):
        self.verify()
        return self.api("PATCH", f"{self.root}/issues/{number}", {"state": "closed"})

    def create(self, title, body):
        self.verify()
        return self.api("POST", self.root + "/issues", {"title": title, "body": body})


def sign(config, item_id, version):
    msg = f"desk-mobile:v1\n{config['repo_id']}\n{item_id}\n{version}".encode()
    return hmac.new(bytes.fromhex(config["signing_key"]), msg, hashlib.sha256).hexdigest()


def field(value, limit):
    if not isinstance(value, str) or not 0 < len(value) <= limit:
        raise Unavailable("invalid projected text")
    # Keep joining characters used by emoji and some writing systems. Strip
    # direction overrides and other controls, and keep every field one line.
    cleaned = "".join(
        " " if ch in "\r\n\t\u2028\u2029" else ch
        for ch in value
        if ch in "\r\n\t\u2028\u2029" + JOINERS or unicodedata.category(ch) not in {"Cc", "Cf", "Cs"}
    )
    return cleaned.strip() or "[text omitted]"


def verify_fields(runner, fields):
    # Reapply the queue's existing secret check before crossing the boundary.
    # Text travels only over stdin and never appears in a diagnostic.
    check = ('source "$1"; while IFS= read -r -d "" value; do '
             'if hq__secret_class "$value"; then exit 5; fi; done')
    runner.call(["/bin/bash", "-c", check, "mobile-check", DESK_BIN / "lib/secrets.sh"],
                input_text="\0".join(value.translate(STRIP_JOINERS) for value in fields) + "\0",
                env={"PATH": os.defpath})


def plain(value):
    without_links = LINK.sub("[link omitted]", value)
    return LOCAL_PATH.sub("[path omitted]", without_links).replace("@", "＠")


def display(value):
    # GitHub parses bodies as Markdown, but these fields are queue text.
    # Entities render as literal punctuation without starting links, images,
    # headings, issue references, or other Markdown constructs.
    return html.escape(plain(value), quote=False).translate(
        {ord(c): f"&#{ord(c)};" for c in r"\`*_{}[]()#+-.!|~:/"}
    )


def projection(runner, config, item):
    if not isinstance(item, dict):
        raise Unavailable("invalid queue item")
    item_id, kind, version = (item.get(k) for k in ("id", "kind", "version"))
    if (not isinstance(item_id, str) or not ITEM.fullmatch(item_id)
            or (kind, item_id[0]) not in {("decision", "D"), ("review", "R")}
            or item.get("status") != "open"):
        raise Unavailable("unexpected queue item")
    if not isinstance(version, str) or not re.fullmatch(r"[1-9][0-9]{0,19}", version):
        raise Unavailable("invalid queue version")
    question = field(item.get("question"), 500)
    options = item.get("options")
    if not isinstance(options, list) or len(options) > 26:
        raise Unavailable("invalid options")
    options = [field(o, 500) for o in options]
    default = item.get("default_option")
    if default is not None:
        default = field(default, 500)
        if options and default not in options:
            raise Unavailable("invalid default")
    verify_fields(runner, [question, *options, *([default] if default else [])])
    marker = f"<!-- desk-mobile:v1 id={item_id} version={version} sig={sign(config, item_id, version)} -->"
    title = f"{item_id} · {plain(question)}"[:240]
    if kind == "review":
        body = marker + "\nReply `reviewed` to mark this Review as read in the desk.\n"
    else:
        lines = [marker, display(question), ""]
        lines += [f"{chr(65 + i)}. {display(o)}" for i, o in enumerate(options)]
        if default:
            lines += ["", "Default: " + display(default)]
        lines += ["", "Reply `answer: A` (an option letter) or `answer: your text`."]
        body = "\n".join(lines) + "\n"
    return {"id": item_id, "version": version, "kind": kind, "title": title, "body": body, "options": len(options)}


def signed_issue(gh, config, issue):
    if ("pull_request" in issue or not gh.owner(issue) or not positive_id(issue.get("number"))
            or not isinstance(issue.get("body"), str) or issue.get("state") != "open"):
        return None
    match = MARKER.match(issue["body"])
    if not match:
        return None
    item_id, version, mac = match.groups()
    if not hmac.compare_digest(mac, sign(config, item_id, version)):
        return None
    return item_id, version


def reply_from(gh, issue, item):
    created = timestamp(issue.get("created_at"))
    valid = []
    for comment in gh.pages(f"/issues/{issue['number']}/comments"):
        if not gh.owner(comment) or not positive_id(comment.get("id")):
            continue
        at = timestamp(comment.get("created_at"))
        if at < created or timestamp(comment.get("updated_at")) != at:
            continue
        body = comment.get("body")
        if not isinstance(body, str):
            continue
        body = body.strip()
        if item["kind"] == "review":
            if body.casefold() == "reviewed":
                valid.append((at, comment["id"], "reviewed", None))
        elif body.lower().startswith("answer:"):
            answer = body[len("answer:"):].strip()
            if not answer or len(answer) > 4000:
                continue
            if (item["options"] and re.fullmatch(r"[A-Za-z]", answer)
                    and ord(answer.upper()) - 64 > item["options"]):
                continue
            valid.append((at, comment["id"], "answer", answer))
    return max(valid, default=None)


def sync(runner, queue, gh, config):
    queue.current()
    # A partial rollout must not export anything it cannot later answer.
    if not isinstance(queue.pending(), list):
        raise Unavailable("mobile receipt storage is unavailable")
    gh.verify()
    rows = queue.open_items()
    if not isinstance(rows, list):
        raise Unavailable("invalid queue list")
    items = {}
    for row in rows:
        item = projection(runner, config, row)
        if item["id"] in items:
            raise Unavailable("duplicate queue item")
        items[item["id"]] = item
    seen = {}
    for issue in gh.pages("/issues?state=open"):
        match = signed_issue(gh, config, issue)
        if match:
            item_id, version = match
            if item_id in seen:
                raise Unavailable("ambiguous signed mirror issues")
            seen[item_id] = issue, version
    for item_id, (issue, version) in list(seen.items()):
        item = items.get(item_id)
        if not item or item["version"] != version:
            queue.current()
            gh.close(issue["number"])
            continue
        if issue.get("title") != item["title"] or issue["body"] != item["body"]:
            # Retire this signed issue and create a clean copy without its replies.
            queue.current()
            gh.close(issue["number"])
            del seen[item_id]
            continue
        result = reply_from(gh, issue, item)
        if result:
            _, comment_id, action, answer = result
            status = queue.apply(config["repo_id"], comment_id, item_id, version, action, answer)
            if status == "applied":
                queue.current()
                gh.close(issue["number"])
            elif status not in {"replay", "stale", "refused"}:
                raise Unavailable("unexpected reply outcome")
    for item_id, item in items.items():
        if item_id in seen and seen[item_id][1] == item["version"]:
            continue
        queue.current()
        created = gh.create(item["title"], item["body"])
        if (not isinstance(created, dict) or not gh.owner(created)
                or not positive_id(created.get("number")) or created.get("body") != item["body"]):
            raise Unavailable("mirror create was not confirmed")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--session", required=True)
    args = parser.parse_args()
    queue = Queue(Runner(), args.session)
    status = 0
    try:
        path = config_path()
        config = load_config(path)
        if config is None:
            print("[]")
            return 0
        lock_path = path.with_name("mobile-sync.lock")
        fd = os.open(lock_path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600)
        with os.fdopen(fd, "rb+") as lock:
            info = os.fstat(lock.fileno())
            if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
                raise Unavailable("mobile lock is not private")
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            runner = Runner()
            queue.runner = runner
            sync(runner, queue, Github(runner, config), config)
    except BlockingIOError:
        pass  # Another pass holds the remote lock. Pending wakes are still readable.
    except (Unavailable, OSError, ValueError, TypeError, RecursionError):
        print("desk mobile inbox: sync could not be verified", file=sys.stderr)
        status = 1
    try:
        # A provider outage cannot erase a previously committed wake pointer.
        queue.runner = Runner(12)
        ids = queue.pending()
        if not isinstance(ids, list) or not all(isinstance(x, str) and ITEM.fullmatch(x) and x[0] == "D" for x in ids):
            raise Unavailable("invalid wake ids")
        print(json.dumps(ids, separators=(",", ":")))
    except (Unavailable, OSError, ValueError, TypeError):
        print("[]")
        status = 1
    return status


if __name__ == "__main__":
    raise SystemExit(main())
