"""review_ledger.py — the money rules for /review-stack-audit's spend ledger.

Issue #1809 (increment 2/5 of #1747). measure.sh imports this module only in
ledger mode (--ledger, implied by --repos and --all-repos), so nothing here can
reach the legacy single-repo path: a failure to import or a bug in this file
fails a ledger run and leaves the measurement-only path untouched.

WHAT A SPEND FIGURE IS
  Every tool gets two fields: `spend_usd` and `spend_source`. The label says
  where the number came from, because an estimate and a receipt look identical
  once both are written down as a number:

    receipt   the vendor's own charge lines (CodeRabbit's `Charged: $X`). A
              FLOOR, never the bill: a summary comment keeps one receipt, and a
              later review on the same PR can overwrite it.
    estimate  an observed count times a published or measured unit rate
              (BugBot check-runs x $/review, Greptile triggers x credit price).
    flat      a fixed monthly fee prorated to the window (CodeAnt; Vercel at a
              known price of $0).
    none      no figure can be computed. `spend_usd` is then null, never 0.

  An unknown price stays unknown. Every place a quick tally would turn a missing
  rate into zero instead yields null plus a note naming the missing input, and a
  null anywhere in a multi-repo sum makes the total null.

WHERE THE RATES LIVE
  One fenced block in .claude/reference/pricing-matrix.md whose info string
  carries the tag `review-stack-rates` and whose JSON declares
  `"schema": "review-stack-rates/v1"`. Prose tables are never parsed: a reworded
  sentence must not be able to move a number. A missing, duplicated, malformed,
  or wrongly-versioned block makes every rate-priced figure null with one note.

MONEY IS DECIMAL
  All arithmetic runs in Decimal cents. Floats appear only at the JSON boundary
  (to_number), and a multi-repo total is summed from the per-repo cents, so a
  total always equals the sum of the figures printed beside it.

Standard library only; must import on macOS system python3 (3.9).
"""

import json
import math
import re
from datetime import datetime, timedelta, timezone
from decimal import Decimal, InvalidOperation, ROUND_HALF_UP
from fractions import Fraction

SCHEMA = "review-stack-rates/v1"
FENCE_TAG = "review-stack-rates"
SPEND_SOURCES = ("receipt", "estimate", "flat", "none")
TOOL_KEYS = ("coderabbit", "codeant", "bugbot", "greptile", "graphite", "vercel")
CODERABBIT_LOGIN = "coderabbitai[bot]"
BUGBOT_CHECK_NAME = "Cursor Bugbot"
# The publisher, not the name, identifies BugBot: any app can post a check
# named `Cursor Bugbot` (the merge gate and escalate-review.sh match both).
BUGBOT_APP_SLUG = "cursor"
CENT = Decimal("0.01")
# A flat monthly fee is prorated by window days / 30, so the default 30-day
# window prices exactly one monthly fee.
MONTH_DAYS = 30

# How each tool is priced. This is a RULE, so it lives here; the rates block
# supplies numbers only. `unit` is the unit the rule multiplies by — a rates
# entry in any other unit cannot be used, because pricing BugBot "per month" as
# if it were "per review" would be silently wrong by a factor of hundreds.
TOOL_RULES = {
    "coderabbit": {"method": "receipt", "unit": "file"},
    "bugbot":     {"method": "per_run", "unit": "review"},
    "greptile":   {"method": "per_trigger", "unit": "credit"},
    "codeant":    {"method": "flat", "unit": "month"},
    "graphite":   {"method": "flat", "unit": "month"},
    "vercel":     {"method": "flat", "unit": "month"},
}

_DATE_RE = re.compile(r"^[0-9]{4}-[0-9]{2}-[0-9]{2}$")
_FENCE_OPEN = re.compile(r"^( {0,3})(`{3,}|~{3,})(.*)$")
# `Charged: $3.25` is CodeRabbit's receipt line. Markdown emphasis around the
# label is tolerated; thousands separators and decimals are accepted.
_CHARGE_RE = re.compile(
    r"\bcharged(?:\*\*)?\s*:\s*(?:\*\*)?\s*\$\s*([0-9][0-9,]*(?:\.[0-9]+)?)", re.I)
_GREPTILE_RE = re.compile(r"(?<![\w@])@greptileai\b", re.I)


# --- rates block -------------------------------------------------------------

def _tagged_fences(text, tag):
    """Bodies of every fenced block whose info-string tokens include `tag`.

    Returns (bodies, error). A fence nested inside another fence is content,
    not a block, so an example of the syntax shown inside a code block is
    never mistaken for the real one. An unterminated tagged fence is an error:
    reading it to end-of-file would parse whatever prose follows as JSON.
    """
    bodies = []
    open_fence = None   # (char, length, is_target, lines)
    for line in text.splitlines():
        if open_fence is None:
            m = _FENCE_OPEN.match(line)
            if not m:
                continue
            marker, info = m.group(2), m.group(3)
            if marker[0] == "`" and "`" in info:
                continue   # not a fence opener (CommonMark: no backtick in info)
            open_fence = (marker[0], len(marker), tag in info.split(), [])
            continue
        char, length, is_target, lines = open_fence
        stripped = line.strip()
        if (len(line) - len(line.lstrip(" ")) <= 3 and stripped
                and set(stripped) == {char} and len(stripped) >= length):
            if is_target:
                bodies.append("\n".join(lines))
            open_fence = None
            continue
        lines.append(line)
    if open_fence is not None and open_fence[2]:
        return bodies, "the `%s` fence is never closed" % tag
    return bodies, None


def _is_number(value):
    # Python's json accepts NaN and Infinity; neither is a price, and either
    # would turn every figure it touches into non-JSON output. An int is always
    # finite, and math.isfinite would overflow on a huge one, so only floats
    # are checked.
    if isinstance(value, bool):
        return False
    if isinstance(value, int):
        return True
    return isinstance(value, float) and math.isfinite(value)


def _check_figure(entry, where):
    """Validate one rate or cap figure. Returns an error string or None."""
    if not isinstance(entry, dict):
        return "%s is not an object" % where
    if "usd" not in entry:
        return "%s has no `usd` (an unknown value is null, never omitted)" % where
    usd = entry["usd"]
    if usd is not None and (not _is_number(usd) or usd < 0):
        return "%s `usd` must be a non-negative number or null" % where
    for field in ("unit", "source"):
        if not isinstance(entry.get(field), str) or not entry[field].strip():
            return "%s needs a non-empty `%s`" % (where, field)
    retrieved = entry.get("retrieved")
    if not isinstance(retrieved, str) or not _DATE_RE.match(retrieved):
        return "%s needs `retrieved` as YYYY-MM-DD" % where
    # `basis: unknown` with a number is the exact confusion the block exists to
    # prevent: a value nobody read, written down as if someone had.
    if entry.get("basis") == "unknown" and usd is not None:
        return "%s has basis `unknown` but a non-null `usd`" % where
    return None


def parse_rates(path):
    """Read the review-stack-rates block from a Markdown file.

    Returns (rates, notes). `rates` is None when the file or block cannot be
    used at all — every rate-priced figure is then null. Otherwise it is
    {"as_of", "tools": {key: entry}, "caps": [entry], "usd": {key: Decimal|None},
     "credits_per_review": Decimal}, where `usd` holds only rates the ledger can
    actually apply. Each tool whose rate is null, missing, or in the wrong unit
    gets one note naming it; an informational rate (CodeRabbit's, since the
    ledger prices CodeRabbit from receipts) never does.
    """
    def unusable(why):
        return None, ["rates unavailable: %s (%s); every rate-priced tool reports "
                      "spend_usd null" % (why, path or "no pricing file")]

    if not path:
        return unusable("no pricing file resolved")
    try:
        with open(path, encoding="utf-8") as fh:
            text = fh.read()
    except (OSError, UnicodeDecodeError) as exc:
        return unusable("cannot read the pricing file: %s" % exc)
    bodies, err = _tagged_fences(text, FENCE_TAG)
    if err:
        return unusable(err)
    if not bodies:
        return unusable("no `%s` fenced block" % FENCE_TAG)
    if len(bodies) > 1:
        return unusable("%d `%s` blocks — exactly one is allowed" % (len(bodies), FENCE_TAG))
    try:
        doc = json.loads(bodies[0])
    except ValueError as exc:
        return unusable("the `%s` block is not valid JSON: %s" % (FENCE_TAG, exc))
    if not isinstance(doc, dict):
        return unusable("the `%s` block is not a JSON object" % FENCE_TAG)
    if doc.get("schema") != SCHEMA:
        return unusable("schema is %r, expected %r" % (doc.get("schema"), SCHEMA))
    if not isinstance(doc.get("as_of"), str) or not _DATE_RE.match(doc["as_of"]):
        return unusable("`as_of` must be YYYY-MM-DD")
    if not isinstance(doc.get("tools"), list):
        return unusable("`tools` must be an array")
    caps = doc.get("caps", [])
    if not isinstance(caps, list):
        return unusable("`caps` must be an array")

    tools = {}
    for i, entry in enumerate(doc["tools"]):
        key = entry.get("key") if isinstance(entry, dict) else None
        if not isinstance(key, str) or not key:
            return unusable("tools[%d] has no `key`" % i)
        if key in tools:
            return unusable("tool %r is listed twice" % key)
        err = _check_figure(entry, "tool %r" % key)
        if err:
            return unusable(err)
        cpr = entry.get("credits_per_review")
        if cpr is not None and (not _is_number(cpr) or cpr <= 0):
            return unusable("tool %r `credits_per_review` must be a positive number" % key)
        tools[key] = entry
    cap_keys = set()
    for i, entry in enumerate(caps):
        key = entry.get("key") if isinstance(entry, dict) else None
        if not isinstance(key, str) or not key:
            return unusable("caps[%d] has no `key`" % i)
        if key in cap_keys:
            return unusable("cap %r is listed twice" % key)
        cap_keys.add(key)
        err = _check_figure(entry, "cap %r" % key)
        if err:
            return unusable(err)

    notes = []
    usd = {}
    for key in TOOL_KEYS:
        rule = TOOL_RULES[key]
        entry = tools.get(key)
        usd[key] = None
        if entry is None:
            if rule["method"] != "receipt":
                notes.append("rates: %s has no entry in the `%s` block, so its "
                             "spend_usd is null" % (key, FENCE_TAG))
            continue
        if entry.get("informational"):
            continue
        if entry["unit"] != rule["unit"]:
            notes.append("rates: %s is priced per %r but the ledger prices %s per %r, "
                         "so its spend_usd is null" % (key, entry["unit"], key, rule["unit"]))
            continue
        if entry["usd"] is None:
            notes.append("rates: %s's per-%s rate is null in the `%s` block (basis: "
                         "%s), so its spend_usd is null, never 0"
                         % (key, entry["unit"], FENCE_TAG, entry.get("basis") or "unstated"))
            continue
        usd[key] = Decimal(str(entry["usd"]))
    greptile = tools.get("greptile") or {}
    credits = greptile.get("credits_per_review")
    rates = {
        "as_of": doc["as_of"],
        "tools": tools,
        "caps": caps,
        "usd": usd,
        "credits_per_review": Decimal(str(credits)) if credits is not None else Decimal(1),
    }
    return rates, notes


# --- signals -----------------------------------------------------------------

def extract_charges(issue_comments):
    """CodeRabbit receipt events: [{"amount": Decimal, "created_at", "pr"}].

    Only comments authored by coderabbitai[bot] count, so a human quoting a
    receipt back (or this repo's own docs quoted by a bot) is never a charge.
    """
    events = []
    for c in issue_comments or []:
        if not isinstance(c, dict) or c.get("user") != CODERABBIT_LOGIN:
            continue
        for m in _CHARGE_RE.finditer(c.get("body") or ""):
            try:
                amount = Decimal(m.group(1).replace(",", ""))
            except InvalidOperation:
                continue
            events.append({"amount": amount, "created_at": c.get("created_at"),
                           "pr": c.get("pr")})
    return events


def _flatten_runs(items):
    for item in items or []:
        if isinstance(item, list):
            for sub in _flatten_runs(item):
                yield sub
        elif isinstance(item, dict) and isinstance(item.get("check_runs"), list):
            # The REST envelope {"total_count", "check_runs": [...]}, one per page.
            for sub in _flatten_runs(item["check_runs"]):
                yield sub
        elif isinstance(item, dict):
            yield item


def _app_slug(run):
    """The publishing app's slug: REST's {"app": {"slug"}} or a normalized string."""
    app = run.get("app")
    if isinstance(app, dict):
        app = app.get("slug")
    return app.strip().lower() if isinstance(app, str) else ""


def bugbot_runs(check_runs):
    """`Cursor Bugbot` check-runs published by the Cursor app, deduplicated by id.

    Accepts runs, REST envelopes, or nested page lists. A run under the name but
    from another app, or with no publisher at all, is not BugBot's and is not
    priced. Dedup is by `id` only: the same run fetched through two commits (or
    two pages) counts once, while a rerun has its own id and counts again — it
    was billed again. A run with no id cannot be matched against anything and
    counts once as itself.
    """
    seen = set()
    runs = []
    for run in _flatten_runs(check_runs):
        if (run.get("name") or "").strip().lower() != BUGBOT_CHECK_NAME.lower():
            continue
        if _app_slug(run) != BUGBOT_APP_SLUG:
            continue
        run_id = run.get("id")
        if run_id is not None:
            if run_id in seen:
                continue
            seen.add(run_id)
        runs.append(run)
    return runs


def greptile_triggers(issue_comments):
    """Comments that trigger a Greptile review: one event per comment.

    A comment mentioning @greptileai twice is still one trigger. Bot authors
    are excluded — Greptile's own footer names its handle, and another bot
    quoting it is not a request for a review.
    """
    events = []
    for c in issue_comments or []:
        if not isinstance(c, dict):
            continue
        user = c.get("user") or ""
        if not user or user.endswith("[bot]"):
            continue
        if _GREPTILE_RE.search(c.get("body") or ""):
            events.append({"created_at": c.get("created_at"), "pr": c.get("pr")})
    return events


def _parse_ts(value):
    if not isinstance(value, str) or not value.strip():
        return None
    text = value.strip()
    if text.endswith(("Z", "z")):
        text = text[:-1] + "+00:00"
    try:
        dt = datetime.fromisoformat(text)
    except ValueError:
        try:
            dt = datetime.strptime(value.strip(), "%Y-%m-%d")
        except ValueError:
            return None
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt


def filter_window(events, since, until, ts_key):
    """Keep events whose `ts_key` falls in the inclusive window.

    `since` and `until` are YYYY-MM-DD strings (either may be None for an open
    bound): the window runs from since 00:00:00Z through until 23:59:59Z.
    Returns (kept, undated) — an event with no parseable timestamp cannot be
    placed in any window, so it is excluded and counted rather than guessed.
    """
    lo = datetime.strptime(since, "%Y-%m-%d").replace(tzinfo=timezone.utc) if since else None
    hi = (datetime.strptime(until, "%Y-%m-%d").replace(tzinfo=timezone.utc)
          + timedelta(days=1)) if until else None
    kept = []
    undated = 0
    for ev in events or []:
        ts = _parse_ts(ev.get(ts_key)) if isinstance(ev, dict) else None
        if ts is None:
            undated += 1
            continue
        if lo is not None and ts < lo:
            continue
        if hi is not None and ts >= hi:
            continue
        kept.append(ev)
    return kept, undated


# --- spend -------------------------------------------------------------------

def cents(value):
    """Round a Decimal to whole cents (half-up)."""
    return value.quantize(CENT, rounding=ROUND_HALF_UP)


def prorate_flat(monthly, window_days):
    """A monthly fee for a window of `window_days` days, in cents.

    A window that has not begun (a future --since gives negative days) bills
    nothing, never a negative fee."""
    days = max(int(window_days), 0)
    return cents(Decimal(monthly) * Decimal(days) / Decimal(MONTH_DAYS))


def compute_spend(tool_key, signals, rates, window_days):
    """(spend Decimal|None, spend_source) for one tool in one repo.

    signals: {"charges": [Decimal], "bugbot_runs": int, "greptile_triggers": int}.
    A null result always carries the `none` label, so the label describes the
    figure actually present; parse_rates already named the missing input.
    """
    rule = TOOL_RULES.get(tool_key)
    if rule is None:
        return None, "none"
    if rule["method"] == "receipt":
        # Zero receipts is a real 0.00 floor, not an unknown: the receipts that
        # exist were read, and there were none in the window.
        total = sum((Decimal(a) for a in signals.get("charges") or []), Decimal(0))
        return cents(total), "receipt"
    rate = (rates or {}).get("usd", {}).get(tool_key) if rates else None
    if rate is None:
        return None, "none"
    if rule["method"] == "per_run":
        return cents(rate * int(signals.get("bugbot_runs") or 0)), "estimate"
    if rule["method"] == "per_trigger":
        credits = rates.get("credits_per_review", Decimal(1))
        return cents(rate * credits * int(signals.get("greptile_triggers") or 0)), "estimate"
    return prorate_flat(rate, window_days), "flat"


def allocate(total, weights):
    """Split `total` (Decimal) across `weights` in whole cents, exactly.

    Largest-remainder in cents, ties to the earlier index, so the parts always
    sum to the total to the cent. All-zero weights split evenly: a flat fee is
    still owed for repos where the tool happened to touch nothing.
    """
    n = len(weights)
    if n == 0:
        return []
    total_cents = int(cents(total) / CENT)
    w = [max(0, int(x)) for x in weights]
    if sum(w) == 0:
        w = [1] * n
    wsum = sum(w)
    raw = [Fraction(total_cents * x, wsum) for x in w]
    base = [r.numerator // r.denominator for r in raw]
    short = total_cents - sum(base)
    order = sorted(range(n), key=lambda i: (-(raw[i] - base[i]), i))
    for i in order[:short]:
        base[i] += 1
    return [Decimal(b) * CENT for b in base]


def sum_spend(figures):
    """Total of per-repo (spend, source) figures for one tool.

    Any null part makes the total null with the `none` label — a total that
    quietly skipped an unknown repo would read as a complete bill.
    """
    if not figures:
        return None, "none"
    if any(usd is None for usd, _ in figures):
        return None, "none"
    total = sum((usd for usd, _ in figures), Decimal(0))
    labels = {label for _, label in figures}
    for label in ("estimate", "flat", "receipt"):
        if label in labels:
            return cents(total), label
    return cents(total), "none"


def to_number(value):
    """Decimal -> JSON number (float), None -> null."""
    return None if value is None else float(cents(value))


def to_decimal(value):
    """JSON number -> Decimal cents, None -> None. Exact for 2-decimal values."""
    return None if value is None else cents(Decimal(repr(float(value))))
