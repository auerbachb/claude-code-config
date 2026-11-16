#!/usr/bin/env python3
"""Antigravity `/usage` panel parser, observation store and optional live capture.

Usage:
  quotas-antigravity.py parse   <text-file|-> <captured-epoch>
  quotas-antigravity.py ingest  <text-file|-> <captured-epoch> <via> <observation-file>
  quotas-antigravity.py show    <observation-file> <now-epoch>
  quotas-antigravity.py capture <agy-bin> <captured-epoch> <observation-file>

The panel prints percent REMAINING per window; this tool reports percent USED
(one decimal). "Refreshes in 153h 32m" becomes an absolute epoch computed from the
capture time; "Quota available" means a full window with no reset. Input that holds
no window yields status "unreadable", never 0%. No credential is read: the live
capture runs the CLI's own slash command and keeps neither stderr nor raw bytes beyond
the panel text. Observation files are written 0600, atomically.
"""
import json
import os
import re
import subprocess
import sys
import tempfile

SCHEMA = "antigravity-usage/1"
MAX_TEXT = 256 * 1024
ANSI = re.compile(r"\x1b(?:\[[0-?]*[ -/]*[@-~]|\][^\x07\x1b]*(?:\x07|\x1b\\)|[@-Z\\-_])")
BAR_CHARS = "█░▓▒▏▎▍▌▋▊▉▕■□▪▫"
PERCENT = re.compile(r"^(\d{1,3}(?:\.\d+)?)\s*%$")
ACCOUNT = re.compile(r"^\s*Account:\s*(.+?)\s*$", re.I)
MODELS = re.compile(r"^\s*Models within this group:\s*(.+?)\s*$", re.I)
REFRESH = re.compile(r"^refreshes\s+in\s+(.+)$", re.I)
DURATION = re.compile(r"(\d+)\s*([dhms])\b", re.I)
UNIT = {"d": 86400, "h": 3600, "m": 60, "s": 1}


def clean_lines(text):
    text = ANSI.sub("", text).replace("\r", "\n")
    out = []
    for raw in text.split("\n"):
        line = "".join(ch for ch in raw if ch >= " " or ch == "\t")
        out.append(line.rstrip())
    return out


def strip_bars(line):
    return re.sub(r"[\[\]|]", "", "".join(" " if ch in BAR_CHARS else ch for ch in line)).strip()


def slug(text):
    return re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-")


def short_group(name):
    s = slug(name)
    s = re.sub(r"(^|-)and(-|$)", "-", s)
    s = re.sub(r"-models?(?=-|$)", "", s)
    return re.sub(r"-+", "-", s).strip("-") or "group"


def window_name(title):
    t = title.lower()
    if re.search(r"\b(five|5)[ -]?hour", t):
        return "5-hour"
    if "weekly" in t:
        return "7-day"
    if "daily" in t:
        return "1-day"
    if "monthly" in t:
        return "30-day"
    t = re.sub(r"\b(remaining|limit)\b", " ", t)
    return slug(t) or "window"


def is_header(line):
    s = line.strip()
    if not s or ":" in s or "%" in s:
        return False
    letters = [c for c in s if c.isalpha()]
    return bool(letters) and all(c.isupper() for c in letters) and len(s) <= 80


def parse_reset(text, captured):
    """-> (resets_at_epoch|None, full, reset_text)"""
    stripped = text.strip()
    if re.fullmatch(r"quota available\.?", stripped, re.I):
        return None, True, stripped
    m = REFRESH.match(stripped)
    if m:
        parts = DURATION.findall(m.group(1))
        if parts:
            seconds = sum(int(n) * UNIT[u.lower()] for n, u in parts)
            return int(captured) + seconds, False, stripped
    return None, False, stripped


def parse_panel(text, captured):
    lines = clean_lines(text[:MAX_TEXT])
    account = None
    groups = []
    group = None
    out_of_range = False
    entries = [(raw, strip_bars(raw)) for raw in lines]
    # Drop blank lines for lookahead but keep order.
    items = [(raw, s) for raw, s in entries if s]
    i = 0
    while i < len(items):
        raw, s = items[i]
        am = ACCOUNT.match(s)
        if am and account is None:
            account = am.group(1)
            i += 1
            continue
        if is_header(s):
            group = {"name": s.title() if s.isupper() else s, "raw_name": s, "slug": short_group(s), "models": [], "windows": []}
            groups.append(group)
            i += 1
            continue
        mm = MODELS.match(s)
        if mm and group is not None:
            group["models"] = [x.strip() for x in mm.group(1).split(",") if x.strip()]
            i += 1
            continue
        # A window title is any line directly followed by a percent line.
        if "%" not in s and i + 1 < len(items) and PERCENT.match(items[i + 1][1]):
            pct = float(PERCENT.match(items[i + 1][1]).group(1))
            reset_line = None
            if i + 2 < len(items) and (REFRESH.match(items[i + 2][1]) or re.fullmatch(r"quota available\.?", items[i + 2][1], re.I)):
                reset_line = items[i + 2][1]
            i += 3 if reset_line else 2
            if not 0.0 <= pct <= 100.0:
                out_of_range = True
                continue
            if group is None:
                group = {"name": "Unknown", "raw_name": "UNKNOWN", "slug": "unknown", "models": [], "windows": []}
                groups.append(group)
            resets, full, reset_text = parse_reset(reset_line or "", captured)
            group["windows"].append({
                "name": window_name(s),
                "title": s,
                "remaining_pct": round(pct, 1),
                "used_pct": round(100.0 - pct, 1),
                "resets_at_epoch": resets,
                "full": full,
                "reset_text": reset_text or None,
            })
            continue
        i += 1
    groups = [g for g in groups if g["windows"]]
    if out_of_range:
        return {"status": "unreadable", "reason": "a percent outside 0-100 was printed; the panel is not trusted", "account": account, "groups": []}
    if not groups:
        return {"status": "unreadable", "reason": "no usage window found in the text", "account": account, "groups": []}
    return {"status": "ok", "account": account, "groups": groups}


def read_text(path):
    data = sys.stdin.buffer.read(MAX_TEXT + 1) if path == "-" else open(path, "rb").read(MAX_TEXT + 1)
    return data.decode("utf-8", "replace")


def write_observation(path, captured, via, text):
    doc = {"schema": SCHEMA, "provider": "antigravity", "captured_at_epoch": int(captured), "via": via, "text": text[:MAX_TEXT]}
    folder = os.path.dirname(os.path.abspath(path))
    os.makedirs(folder, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".agy-obs.", dir=folder)
    try:
        with os.fdopen(fd, "w") as handle:
            json.dump(doc, handle)
        os.chmod(tmp, 0o600)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def main(argv):
    if len(argv) < 2:
        print(__doc__, file=sys.stderr)
        return 2
    cmd = argv[1]
    try:
        if cmd == "parse" and len(argv) == 4:
            print(json.dumps(parse_panel(read_text(argv[2]), int(argv[3]))))
            return 0
        if cmd == "ingest" and len(argv) == 6:
            text = read_text(argv[2])
            result = parse_panel(text, int(argv[3]))
            if result["status"] != "ok":
                print(json.dumps(result))
                return 3
            write_observation(argv[5], int(argv[3]), argv[4], text)
            print(json.dumps(result))
            return 0
        if cmd == "show" and len(argv) == 4:
            try:
                doc = json.load(open(argv[2]))
            except FileNotFoundError:
                print(json.dumps({"status": "missing"}))
                return 0
            except (OSError, ValueError):
                print(json.dumps({"status": "unreadable", "reason": "observation file is not valid JSON"}))
                return 0
            if not isinstance(doc, dict) or doc.get("schema") != SCHEMA or not isinstance(doc.get("text"), str) \
                    or not isinstance(doc.get("captured_at_epoch"), int) or isinstance(doc.get("captured_at_epoch"), bool):
                print(json.dumps({"status": "unreadable", "reason": "observation file has an unknown shape"}))
                return 0
            captured = doc["captured_at_epoch"]
            result = parse_panel(doc["text"], captured)
            result.update(captured_at_epoch=captured, age_seconds=max(0, int(argv[3]) - captured),
                          via=doc.get("via") if isinstance(doc.get("via"), str) else "unknown")
            print(json.dumps(result))
            return 0
        if cmd == "capture" and len(argv) == 5:
            try:
                proc = subprocess.run([argv[2], "-p", "/usage"], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                      stderr=subprocess.DEVNULL, timeout=90, check=False)
            except subprocess.TimeoutExpired:
                print(json.dumps({"status": "unreadable", "reason": "agy did not answer within 90s"}))
                return 3
            except OSError:
                print(json.dumps({"status": "unreadable", "reason": "agy could not be started"}))
                return 3
            text = proc.stdout[:MAX_TEXT].decode("utf-8", "replace")
            result = parse_panel(text, int(argv[3]))
            if result["status"] != "ok":
                result["reason"] = "agy -p /usage printed no usage panel (exit %d); use the manual route" % proc.returncode
                print(json.dumps(result))
                return 3
            write_observation(argv[4], int(argv[3]), "agy-print", text)
            print(json.dumps(result))
            return 0
    except (ValueError, OSError) as exc:
        print(json.dumps({"status": "unreadable", "reason": "%s" % type(exc).__name__}))
        return 3
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
