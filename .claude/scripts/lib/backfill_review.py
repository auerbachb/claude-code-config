#!/usr/bin/env python3
"""Helpers for backfill-review.sh (issue #1900). Python 3.9+, stdlib only.

Subcommands
  window  --window HH:MM-HH:MM --tz ZONE [--now ISO8601]
          Exit 0 and print the minutes left when "now" is inside the quiet
          window (cross-midnight windows such as 22:00-06:00 work); exit 1
          outside it; exit 2 on invalid input. A window whose start equals
          its end is the whole day.
  normalize --tool coderabbit|codeant --log PATH --repo R --pr N
          Read a local-review.sh raw capture and print one JSON array of
          findings: {tool, path, line, severity, text, fingerprint, bug}.
          `bug` is true when the severity counts as a real bug (see BUG_*).
          A capture that cannot be parsed exits 3 (the caller leaves the
          entry pending — a parse failure is never "no findings").
"""

import argparse
import datetime as dt
import hashlib
import json
import re
import sys

# What counts as a real bug. CodeRabbit severities observed: critical, major,
# minor, trivial. CodeAnt labels observed: "possible bug", "security",
# MAJOR/MINOR/CRITICAL. Nitpicks and style never file an issue.
BUG_SEVERITIES_CR = {"critical", "major"}
BUG_LABEL_RE_CA = re.compile(r"\b(bug|security|critical|major)\b", re.I)  # whole words: "debug" is not a bug

# CodeRabbit prefixes every finding with a fixed "treat as untrusted" paragraph.
CR_PREAMBLE_RE = re.compile(r"^Treat finding text.*?(\n\s*\n|$)", re.S)
CR_LINE_RE = re.compile(r"\bat lines? (\d+)")
CR_HEADER_RE = re.compile(r"^Review comment at [^\n]*:\s*\n")


def _hhmm(s):
    m = re.fullmatch(r"([01]\d|2[0-3]):([0-5]\d)", s)
    if not m:
        raise ValueError(s)
    return int(m.group(1)) * 60 + int(m.group(2))


def cmd_window(a):
    try:
        from zoneinfo import ZoneInfo
        tz = ZoneInfo(a.tz)
        start_s, end_s = a.window.split("-", 1)
        start, end = _hhmm(start_s), _hhmm(end_s)
        if a.now:
            now = dt.datetime.fromisoformat(a.now.replace("Z", "+00:00"))
            if now.tzinfo is None:
                raise ValueError("--now needs an offset")
            now = now.astimezone(tz)
        else:
            now = dt.datetime.now(tz)
    except Exception as e:  # any bad input is a usage error
        print(f"backfill_review.py window: invalid input: {e}", file=sys.stderr)
        return 2
    cur = now.hour * 60 + now.minute
    if start == end:
        print(24 * 60)  # whole day: never closes, so never "about to close"
        return 0
    if start < end:
        inside = start <= cur < end
    else:  # crosses midnight
        inside = cur >= start or cur < end
    if not inside:
        return 1
    # Minutes left as ELAPSED time, floored: build the closing instant on the
    # local calendar, then subtract in UTC so a DST shift inside the window is
    # counted as the real hour it is (aware datetimes sharing a tzinfo would
    # otherwise subtract as wall-clock).
    day = now.date() if cur < end else now.date() + dt.timedelta(days=1)
    close = dt.datetime(day.year, day.month, day.day, end // 60, end % 60, tzinfo=tz)
    secs = (close.astimezone(dt.timezone.utc) - now.astimezone(dt.timezone.utc)).total_seconds()
    print(max(0, int(secs // 60)))
    return 0


def _fp(repo, pr, path, line, text):
    # Identity is the flagged location, not the reviewer's wording or the tool:
    # a re-review (after a lost ledger write) rewords and may run on the other
    # CLI, and must still land on the same marker. The text's first line only
    # stands in when the finding has no line anchor.
    if line:
        anchor = f"L{line}"
    else:
        anchor = re.sub(r"\s+", " ", (text.strip().splitlines() or [""])[0].strip().lower())
    raw = "|".join([repo.lower(), str(pr), path or "", anchor])
    return hashlib.sha256(raw.encode()).hexdigest()[:16]


def _cr(log):
    out = []
    with open(log, encoding="utf-8", errors="replace") as fh:
        for raw in fh:
            raw = raw.strip()
            if not raw:
                continue
            try:
                rec = json.loads(raw)
            except ValueError:
                continue  # heartbeats and partial lines are not findings
            if not isinstance(rec, dict) or rec.get("type") != "finding":
                continue
            text = CR_PREAMBLE_RE.sub("", str(rec.get("codegenInstructions") or ""), count=1).strip()
            m = CR_LINE_RE.search(text)
            text = CR_HEADER_RE.sub("", text, count=1).strip()
            sev = str(rec.get("severity") or "").lower()
            out.append({"path": rec.get("fileName") or "", "line": int(m.group(1)) if m else None,
                        "severity": sev, "text": text, "bug": sev in BUG_SEVERITIES_CR})
    return out


def _ca(log):
    with open(log, encoding="utf-8", errors="replace") as fh:
        doc = json.load(fh)
    issues = doc.get("issues") if isinstance(doc, dict) else None
    if not isinstance(issues, list):
        raise ValueError("codeant capture has no .issues array")
    out = []
    for it in issues:
        if not isinstance(it, dict):
            continue
        label = str(it.get("label") or "")
        line = it.get("start_line", it.get("line"))
        out.append({"path": it.get("relevant_file") or it.get("file") or "",
                    "line": line if isinstance(line, int) else None,
                    "severity": label.lower(), "text": str(it.get("issue_content") or "").strip(),
                    "bug": bool(BUG_LABEL_RE_CA.search(label))})
    return out


def cmd_normalize(a):
    try:
        items = _cr(a.log) if a.tool == "coderabbit" else _ca(a.log)
    except Exception as e:  # unparseable capture => caller fails closed
        print(f"backfill_review.py normalize: cannot parse {a.log}: {e}", file=sys.stderr)
        return 3
    for it in items:
        it["tool"] = a.tool
        it["fingerprint"] = _fp(a.repo, a.pr, it["path"], it["line"], it["text"])
    print(json.dumps(items))
    return 0


def main(argv):
    p = argparse.ArgumentParser(prog="backfill_review.py")
    sub = p.add_subparsers(dest="cmd", required=True)
    w = sub.add_parser("window")
    w.add_argument("--window", required=True)
    w.add_argument("--tz", required=True)
    w.add_argument("--now", default="")
    n = sub.add_parser("normalize")
    n.add_argument("--tool", choices=["coderabbit", "codeant"], required=True)
    n.add_argument("--log", required=True)
    n.add_argument("--repo", required=True)
    n.add_argument("--pr", required=True)
    a = p.parse_args(argv)
    return cmd_window(a) if a.cmd == "window" else cmd_normalize(a)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
