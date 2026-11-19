#!/usr/bin/env python3
"""Render verified project-board rows to a single private local page."""
import argparse
import base64
from datetime import datetime
import fcntl
import hashlib
from html import escape
import json
import os
from pathlib import Path
import re
import stat
import sys
import tempfile
import time
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError


GROUPS = {"needs": "Needs you", "running": "Running", "queued": "Queued", "done": "Done"}
REPO_RE = re.compile(r"[a-z0-9-]+/[a-z0-9_.-]+")
CREDENTIAL_RE = re.compile(
    r"(?i)\b(?:gh[pousr]_[a-z0-9]{12,}|github_pat_[a-z0-9_]{12,}|"
    r"sk-[a-z0-9_-]{12,}|eyJ[a-z0-9_-]+\.[a-z0-9_-]+\.[a-z0-9_-]+|"
    r"(?:bearer|basic)[ \t]+[^\s,]+|(?:api[ _-]?key|password|secret|token)[ \t]*[=:][ \t]*[^\s,]+)"
)
NOTE_RE = re.compile(r"[a-zA-Z0-9][a-zA-Z0-9_. -]{0,99}\.(?:md|json|txt)")
MAX_INPUT = 2_000_000


def positive_number(value):
    return type(value) is int and 0 < value <= 2_147_483_647


def display_title(value):
    if not isinstance(value, str):
        return ""
    value = "".join(ch for ch in value if ch.isprintable()).strip()
    return CREDENTIAL_RE.sub("[redacted]", value)[:160]


def display_estimate(value):
    if not isinstance(value, dict):
        return None
    low, high, plan = (value.get(field) for field in ("low", "high", "plan"))
    if not all(positive_number(part) for part in (low, high, plan)) or not low <= high:
        return None
    span = str(low) if low == high else f"{low}–{high}"
    return f"Est {span} min · plan on {plan}"


def display_finish(value):
    if not isinstance(value, str) or not re.fullmatch(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z", value):
        return None
    try:
        timestamp = datetime.fromisoformat(value[:-1] + "+00:00")
    except ValueError:
        return None
    try:
        local = timestamp.astimezone(ZoneInfo("America/New_York"))
    except ZoneInfoNotFoundError:
        local = timestamp
    return value, local.strftime("%b %d, %I:%M %p %Z").replace(", 0", ", ")


def scoped_notes(root, repo):
    directory = root
    for part in (None, *repo.split("/")):
        if part is not None:
            directory = directory / part
        try:
            info = directory.lstat()
        except FileNotFoundError:
            return []
        if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid():
            return []
    with os.scandir(directory) as entries:
        return [{"repo": repo, "name": entry.name} for entry in entries
                if entry.is_file(follow_symlinks=False)]


def project(payload, repo, local_notes):
    if not isinstance(payload, dict) or payload.get("repo") != repo:
        raise ValueError("board evidence does not match the selected repo")
    rows = payload.get("rows")
    notes = payload.get("notes", [])
    if not isinstance(rows, list) or not isinstance(notes, list):
        raise ValueError("board evidence requires row and note arrays")
    groups = {group: [] for group in GROUPS}
    seen = set()
    for row in rows:
        if not isinstance(row, dict):
            raise ValueError("invalid board row")
        if row.get("repo") != repo:
            continue
        issue, group = row.get("issue"), row.get("group")
        if not positive_number(issue) or not isinstance(group, str) or group not in GROUPS or issue in seen:
            raise ValueError("invalid or duplicate issue in board evidence")
        seen.add(issue)
        phase = row.get("phase")
        if phase not in ("A", "B", "C"):
            phase = None
        parent = row.get("parent")
        if not positive_number(parent) or parent == issue:
            parent = None
        pr = row.get("pr")
        outcome = row.get("outcome")
        if group == "done" and outcome not in ("merged", "blocked"):
            raise ValueError("done rows require a verified terminal outcome")
        if outcome == "merged" and (group != "done" or not positive_number(pr)):
            raise ValueError("a merged row requires its verified PR")
        groups[group].append({
            "issue": issue,
            "pr": pr if positive_number(pr) else None,
            "title": display_title(row.get("title")),
            "phase": phase,
            "parent": parent,
            "estimate": display_estimate(row.get("estimate")),
            "finish": display_finish(row.get("ends_at")),
            "outcome": outcome,
        })
    names = set()
    for note in notes + local_notes:
        if isinstance(note, dict) and note.get("repo") == repo:
            name = note.get("name")
            if isinstance(name, str) and NOTE_RE.fullmatch(name) and not CREDENTIAL_RE.search(name):
                names.add(name)
    receipt = payload.get("receipt")
    counts = None
    if isinstance(receipt, dict) and receipt.get("repo") == repo:
        statuses = receipt.get("statuses")
        if (isinstance(statuses, list) and statuses and len(statuses) <= 32
                and all(status in ("ran", "skipped", "failed", "unrecorded") for status in statuses)):
            counts = {status: statuses.count(status) for status in ("ran", "skipped", "failed", "unrecorded")}
    return groups, sorted(names), counts


REFRESH = """
const list = document.querySelector("#list");
const columns = document.querySelector("#columns");
if (location.hash === "#column-view") columns.checked = true;
for (const option of [list, columns]) {
  option.addEventListener("change", () => {
    history.replaceState(null, "", columns.checked ? "#column-view" : "#list-view");
  });
}
const refreshAfter = Date.now() + 60000;
function refreshWhenVisible() {
  if (Date.now() >= refreshAfter && document.visibilityState === "visible") location.reload();
}
setTimeout(refreshWhenVisible, 60000);
document.addEventListener("visibilitychange", refreshWhenVisible);
"""
REFRESH_HASH = base64.b64encode(hashlib.sha256(REFRESH.encode("utf-8")).digest()).decode("ascii")


CSS = """
:root {
  color-scheme: light dark;
  --bg: #f3f5f7;
  --card: #ffffff;
  --text: #17212a;
  --muted: #495969;
  --line: #d8e0e7;
  --accent: #045c54;
  --control: #e4efec;
}
@media (prefers-color-scheme: dark) {
  :root {
    --bg: #151a20;
    --card: #1f2730;
    --text: #eef3f7;
    --muted: #aebbc7;
    --line: #3b4958;
    --accent: #82dfcc;
    --control: #263c3a;
  }
}
* { box-sizing: border-box; }
body {
  margin: 0;
  background: var(--bg);
  color: var(--text);
  font: 15px/1.5 Inter, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
}
main { max-width: 1240px; margin: auto; padding: clamp(16px, 3vw, 36px); }
header { display: flex; flex-wrap: wrap; align-items: baseline; justify-content: space-between; gap: 8px 16px; }
h1 { margin: 0 0 16px; font-size: clamp(23px, 4vw, 34px); overflow-wrap: anywhere; }
h2, h3 { margin: 0; font-weight: 650; }
h2 { font-size: 16px; }
h3 { font-size: 14px; }
a { color: var(--accent); text-underline-offset: 3px; }
:focus-visible { outline: 3px solid var(--accent); outline-offset: 3px; }
.layout-choice { position: absolute; width: 1px; height: 1px; opacity: 0; }
label {
  display: inline-block;
  cursor: pointer;
  padding: 5px 12px;
  border: 1px solid var(--line);
  border-radius: 5px;
  margin-right: 5px;
}
#list:checked + label, #columns:checked + label { background: var(--control); }
.layout-choice:focus-visible + label { outline: 3px solid var(--accent); outline-offset: 3px; }
.lanes { display: grid; gap: 14px; margin: 18px 0; align-items: start; }
#columns:checked ~ .lanes { grid-template-columns: repeat(4, minmax(0, 1fr)); }
.lane, aside { background: var(--card); border: 1px solid var(--line); border-radius: 8px; padding: 13px; min-width: 0; }
.lane h2, aside h2 { display: flex; gap: 8px; align-items: baseline; }
.lane h2 small, .meta, .empty, .chain h3 small { color: var(--muted); font-size: 13px; }
ul { padding: 0; margin: 0; list-style: none; }
.item, .chain { border-top: 1px solid var(--line); margin-top: 9px; padding-top: 9px; overflow-wrap: anywhere; }
.item > a:first-child { font-weight: 650; }
.chain ul { margin-left: 9px; padding-left: 9px; border-left: 1px solid var(--line); }
.chain ul .item { border-top: 0; }
.meta { display: flex; flex-wrap: wrap; gap: 2px 12px; margin-top: 3px; }
.empty { margin: 8px 0 0; }
.notes { margin-top: 8px; overflow-wrap: anywhere; }
@media (max-width: 960px) { #columns:checked ~ .lanes { grid-template-columns: repeat(2, minmax(0, 1fr)); } }
@media (max-width: 520px) { #columns:checked ~ .lanes { grid-template-columns: minmax(0, 1fr); } }
"""


def issue_link(repo, issue):
    return f'<a href="https://github.com/{repo}/issues/{issue}">#{issue}</a>'


def item_html(row, repo):
    issue = row["issue"]
    title = escape(row["title"])
    meta = []
    if row["pr"]:
        pr = row["pr"]
        meta.append(f'<a href="https://github.com/{repo}/pull/{pr}">PR #{pr}</a>')
    if row["phase"]:
        meta.append(f'<span>Phase {row["phase"]}</span>')
    if row["outcome"] == "blocked":
        meta.append("<span>Blocked</span>")
    if row["estimate"]:
        meta.append(f'<span>{escape(row["estimate"])}</span>')
    if row["finish"]:
        iso, label = row["finish"]
        meta.append(f'<time datetime="{iso}">{escape(label)}</time>')
    details = f'<div class="meta">{"".join(meta)}</div>' if meta else ""
    return f'<li class="item">{issue_link(repo, issue)} {title}{details}</li>'


def group_html(group, rows, repo, chain_totals):
    children = {}
    for row in rows:
        if row["parent"]:
            children.setdefault(row["parent"], []).append(row)
    cards = []
    rendered = set()
    for row in rows:
        parent = row["parent"]
        if parent is None:
            cards.append(item_html(row, repo))
        elif parent not in rendered:
            rendered.add(parent)
            done, total = chain_totals[parent]
            nested = "".join(item_html(child, repo) for child in children[parent])
            cards.append(
                f'<li class="chain"><h3>{issue_link(repo, parent)} '
                f'<small>{done} of {total} done</small></h3><ul>{nested}</ul></li>'
            )
    contents = f'<ul>{"".join(cards)}</ul>' if cards else '<p class="empty">None</p>'
    if group == "needs" and rows:
        contents += (
            '<p class="meta"><span>Respond through <a href="https://github.com/auerbachb/'
            'claude-code-config/blob/main/desk/skill/SKILL.md">/desk</a>.</span></p>'
        )
    return (
        f'<section class="lane" aria-labelledby="{group}-heading">'
        f'<h2 id="{group}-heading">{GROUPS[group]} <small>{len(rows)}</small></h2>'
        f'{contents}</section>'
    )


def render(repo, groups, notes, receipt):
    chain_totals = {}
    for rows in groups.values():
        for row in rows:
            parent = row["parent"]
            if parent:
                done, total = chain_totals.get(parent, (0, 0))
                chain_totals[parent] = (done + (row["outcome"] == "merged"), total + 1)
    lanes = "".join(group_html(group, rows, repo, chain_totals) for group, rows in groups.items())
    run_summary = ""
    if receipt:
        counts = " · ".join(f"{count} {status}" for status, count in receipt.items() if count)
        run_summary = f'<p class="meta">Latest PM run · {counts}</p>'
    library = ""
    if notes:
        library = '<aside><h2>Handoffs and notes</h2><ul class="notes">' + "".join(
            f"<li>{escape(note)}</li>" for note in notes
        ) + "</ul></aside>"
    return f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; script-src 'sha256-{REFRESH_HASH}'; base-uri 'none'; form-action 'none'">
<title>{repo} · Project board</title>
<style>{CSS}</style>
</head>
<body>
<main>
<header><h1>{repo}</h1>{run_summary}</header>
<input id="list" class="layout-choice" type="radio" name="layout" checked><label for="list">List</label>
<input id="columns" class="layout-choice" type="radio" name="layout"><label for="columns">Columns</label>
<div class="lanes">{lanes}</div>
{library}
</main>
<script>{REFRESH}</script>
</body>
</html>
""".encode("utf-8")


def board_path(root, repo, create):
    if create:
        root.mkdir(mode=0o700, parents=True, exist_ok=True)
    directory = root
    for part in (None, *repo.split("/")):
        if part is not None:
            directory = directory / part
            if create:
                directory.mkdir(mode=0o700, exist_ok=True)
        try:
            info = directory.lstat()
        except FileNotFoundError:
            if create:
                raise
            return None
        if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
            raise ValueError("invalid board directory")
    return directory / "board.html"


def read_page(path):
    if path is None:
        return None
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except FileNotFoundError:
        return None
    with os.fdopen(fd, "rb") as previous:
        info = os.fstat(previous.fileno())
        if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid()
                or info.st_nlink != 1 or info.st_mode & 0o077):
            raise ValueError("invalid board output file")
        page = previous.read(8 * MAX_INPUT + 1)
        if len(page) > 8 * MAX_INPUT:
            raise ValueError("existing board output is too large")
        return page


def digest(page):
    return hashlib.sha256(page).hexdigest() if page is not None else None


def publish(root, repo, page, expected):
    path = board_path(root, repo, create=True)
    lock_flags = os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW | os.O_NONBLOCK
    lock = os.open(path.parent / ".board.lock", lock_flags, 0o600)
    with os.fdopen(lock, "rb+") as stream:
        info = os.fstat(stream.fileno())
        if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid()
                or info.st_nlink != 1 or info.st_mode & 0o077):
            raise ValueError("invalid board lock")
        deadline = time.monotonic() + 4
        while True:
            try:
                fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if time.monotonic() >= deadline:
                    raise ValueError("board publication is already in progress") from None
                time.sleep(0.02)
        previous = read_page(path)
        if previous == page:
            return path, False
        if (digest(previous) or "absent") != expected:
            raise ValueError("board changed while gathering evidence; collect again")
        pending = None
        try:
            with tempfile.NamedTemporaryFile(mode="wb", dir=path.parent, prefix=".board-", delete=False) as output:
                pending = Path(output.name)
                output.write(page)
                output.flush()
                os.fsync(output.fileno())
            pending.replace(path)
        finally:
            if pending is not None:
                pending.unlink(missing_ok=True)
    return path, True


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", required=True)
    parser.add_argument("--root", type=Path, default=Path.home() / ".claude/boards")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--current", action="store_true", help="inspect the current local page")
    mode.add_argument("--html", action="store_true", help="emit the validated HTML without writing files")
    parser.add_argument("--expect-digest", help="guard publication against an older evidence snapshot")
    args = parser.parse_args()
    if args.current or args.html:
        if args.expect_digest is not None:
            parser.error("--expect-digest is only for local publication")
    elif not re.fullmatch(r"absent|[0-9a-f]{64}", args.expect_digest or ""):
        parser.error("publication requires --expect-digest with a prior digest or absent")
    repo = args.repo.lower()
    if not REPO_RE.fullmatch(repo) or repo.split("/")[1] in (".", ".."):
        parser.error("expected a GitHub owner/repo")
    try:
        root = args.root.absolute()
        if args.current:
            path = board_path(root, repo, create=False)
            previous = read_page(path)
            print(json.dumps({"repo": repo, "path": str(path) if previous is not None else None,
                              "digest": digest(previous)}))
            return
        raw = sys.stdin.buffer.read(MAX_INPUT + 1)
        if len(raw) > MAX_INPUT:
            raise ValueError("board evidence is too large")
        notes_root = Path.home() / ".claude/handoffs"
        groups, notes, receipt = project(json.loads(raw), repo, scoped_notes(notes_root, repo))
        page = render(repo, groups, notes, receipt)
        if args.html:
            sys.stdout.buffer.write(page)
            return
        path, updated = publish(root, repo, page, args.expect_digest)
        print(json.dumps({"repo": repo, "path": str(path),
                          "digest": digest(page), "updated": updated}))
    except (OSError, ValueError) as error:
        parser.exit(2, f"pm-board-page: {error}\n")


if __name__ == "__main__":
    main()
