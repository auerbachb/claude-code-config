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

WHAT A FINDING WAS WORTH (issue #1810, increment 3/5)
  Every review thread a tool opens is one finding, and the replies to it carry
  its verdict: `fixed`, `deferred`, `declined`, or `unanswered`. Only replies
  after the first comment, from a GitHub `User` account, count. An explicit
  `<!-- review-verdict: ... -->` marker beats wording, and only a marker can
  say a finding was a real defect. The per-tool value fields (precision, cost
  per real defect, median response time) are derived here; the rules are
  documented in .claude/reference/review-stack-audit.md "Value fields".
  Follow-up links are read by lib/deferred-refs.jq — the merge gate's own
  parser — through one `jq` call per run, so the two never disagree.

Standard library only (plus the `jq` binary for the shared link parser); must
import on macOS system python3 (3.9).
"""

import json
import math
import os
import re
import statistics
import subprocess
from datetime import datetime, timedelta, timezone
from decimal import Decimal, InvalidOperation, ROUND_HALF_UP
from fractions import Fraction

SCHEMA = "review-stack-rates/v1"
FENCE_TAG = "review-stack-rates"
SPEND_SOURCES = ("receipt", "estimate", "flat", "none")
TOOL_KEYS = ("coderabbit", "codeant", "bugbot", "greptile", "graphite", "vercel")
CODERABBIT_LOGIN = "coderabbitai[bot]"
BUGBOT_CHECK_NAME = "Cursor Bugbot"
# No price, cap, or credit count comes near a billion. Anything at or above it
# is a typo, and Decimal's default 28-digit context could not quantize the cents
# it would produce, so the block refuses it rather than crash a later pricing.
MAX_FIGURE = 10 ** 9
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
# A receipt is its own line — CodeRabbit writes `- Charged: $0.50` as a list
# item — so the match is anchored to the start of a line (an optional list
# marker and bold allowed). Prose that merely quotes a `Charged: $X` line
# mid-sentence, as a summary describing this very ledger would, is not a charge.
_CHARGE_RE = re.compile(
    r"^[ \t]*(?:[-*+][ \t]+)?(?:\*\*)?charged(?:\*\*)?[ \t]*:[ \t]*(?:\*\*)?[ \t]*"
    r"\$[ \t]*([0-9][0-9,]*(?:\.[0-9]+)?)", re.I | re.M)
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
    if usd is not None and (not _is_number(usd) or usd < 0 or usd >= MAX_FIGURE):
        return "%s `usd` must be a non-negative number below %d, or null" % (where, MAX_FIGURE)
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
     "credits_per_review": Decimal|None}, where `usd` holds only rates the ledger
    can actually apply. Each tool whose rate is null, missing, or in the wrong
    unit gets one note naming it, as does Greptile when its credits per review
    are unknown; an informational rate on CodeRabbit (priced from receipts)
    never does.
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
        if cpr is not None and (not _is_number(cpr) or cpr <= 0 or cpr >= MAX_FIGURE):
            return unusable("tool %r `credits_per_review` must be a positive number below %d"
                            % (key, MAX_FIGURE))
        # Only a real boolean: the string "false" is truthy and would silently
        # drop a valid rate from the ledger.
        if "informational" in entry and not isinstance(entry["informational"], bool):
            return unusable("tool %r `informational` must be true or false" % key)
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
            # Recorded for reference, never priced. Silent only for a
            # receipt-priced tool, whose spend reads no rate; any other tool's
            # spend goes null, and the note says why.
            if rule["method"] != "receipt":
                notes.append("rates: %s is marked informational in the `%s` block, so "
                             "its rate is not used and its spend_usd is null"
                             % (key, FENCE_TAG))
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
    # A $/credit rate prices a review only with a credits-per-review figure.
    # Absent or null, a review's cost is unknown: null, never assumed 1 credit.
    if usd.get("greptile") is not None and credits is None:
        usd["greptile"] = None
        notes.append("rates: greptile has no `credits_per_review` in the `%s` block, "
                     "so its spend_usd is null, never an assumed 1 credit" % FENCE_TAG)
    rates = {
        "as_of": doc["as_of"],
        "tools": tools,
        "caps": caps,
        "usd": usd,
        "credits_per_review": Decimal(str(credits)) if credits is not None else None,
    }
    return rates, notes


# --- signals -----------------------------------------------------------------

def extract_charges(issue_comments):
    """CodeRabbit receipt events: [{"amount": Decimal, "at", "created_at", "pr"}].

    Only comments authored by coderabbitai[bot] count, so a human quoting a
    receipt back (or this repo's own docs quoted by a bot) is never a charge.
    `at` times the receipt by the comment's last edit (`updated_at`, falling
    back to `created_at`): CodeRabbit rewrites its summary comment in place, so
    the receipt it shows belongs to the review that last edited it.
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
            events.append({"amount": amount,
                           "at": c.get("updated_at") or c.get("created_at"),
                           "created_at": c.get("created_at"), "pr": c.get("pr")})
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
        credits = rates.get("credits_per_review")
        if credits is None:
            return None, "none"
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


# --- reply verdicts and value fields (issue #1810) ---------------------------
#
# A finding is a review thread whose FIRST comment a review tool wrote. Its
# verdict comes from the replies after that comment, and only from replies by a
# GitHub `User` account — the PR author, a collaborator, or an agent posting as
# the user. A bot's reply, the tool's own follow-ups included, never decides a
# verdict, and GraphQL bot logins carry no `[bot]` suffix, so the account TYPE
# is what is tested (measure.sh normalizes it as `user_type`).
#
# Per reply, after quoted lines (`> ...`) are removed:
#   marker    `<!-- review-verdict: fixed|deferred|declined defect=real|not
#             agent=<name> -->` outside any code span or fenced block. It beats
#             wording. A marker whose verdict is unknown is ignored (and noted),
#             and the reply is read by its wording instead.
#   declined  the reply STARTS with `Declined`, `Not a defect`, or `Won't fix`
#             (straight or curly apostrophe), after any leading @mentions,
#             HTML comments, emphasis, and fenced blocks (wording inside a
#             fence is an example, never a verdict). The opening verb is the stated
#             disposition, so it beats a commit or issue number cited later in
#             the reply ("Declined: same as the pattern in #1222" is a decline
#             that cites a PR, and the ledger cannot look the number up).
#   fixed     `Fixed in <sha>` anywhere outside a fenced code block (7-40 hex
#             digits, backticks and a `commit` word tolerated).
#   deferred  a follow-up link in the forms the merge gate accepts, read by the
#             gate's own parser (lib/deferred-refs.jq). Syntax only: unlike the
#             gate, the ledger does not look the number up.
# Per thread: the LATEST marker wins over everything; with no marker, the latest
# reply whose wording matched wins; with neither, the thread is `unanswered`.
# Only a marker can make a finding a real defect (`defect=real`) — a `Fixed in`
# reply without one is fixed, not a real defect.

VERDICTS = ("fixed", "deferred", "declined")
DEFERRED_REFS_MODULE = "deferred-refs.jq"

_MARKER_RE = re.compile(r"<!--[ \t]*review-verdict[ \t]*:([^\n]*?)-->", re.I)
_AGENT_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,63}")
# Code is shown, not hidden: a marker quoted inside a fenced block or a code span
# is an example of the syntax, not a verdict. A fence closes on a line of the
# same character at least as long as its opener (CommonMark), so a ```` line
# closes a ``` block but a ``` line never closes a ```` one. An unterminated
# fence runs to the end of the body, as CommonMark reads it. Code spans are
# matched within one line, so an unmatched backtick never scans past its own
# line; a marker is one line anyway.
_FENCED_RE = re.compile(r"^[ \t]{0,3}(?:(`{3,})|(~{3,}))[^\n]*\n.*?"
                        r"(?:^[ \t]{0,3}(?(1)\1`*|\2~*)[ \t]*$|\Z)",
                        re.M | re.S)
_CODE_SPAN_RE = re.compile(r"(?<!`)(`+)(?!`)[^\n]+?(?<!`)\1(?!`)")
# Up to three emphasis characters may open the decline (`*`, `**`, `***`,
# `_..._`, `**_..._**`), so the word boundary after it ignores an underscore:
# `_Declined_` is emphasis, not an identifier.
_DECLINED_RE = re.compile(
    r"\A\s*(?:<!--.*?-->\s*)*(?:@[A-Za-z0-9][A-Za-z0-9_-]*(?:\[bot\])?[\s,:]*)*"
    r"[*_]{0,3}(?:declined|not[ \t]+a[ \t]+defect|won['’]t[ \t]+fix)(?![^\W_])",
    re.I | re.S)
_FIXED_RE = re.compile(
    r"(?<![\w-])fixed[ \t]+in[ \t]+(?:commit[ \t]+)?`?[0-9a-f]{7,40}`?(?!\w)", re.I)

# The comment that asks each tool for a review, by the commands the rules
# document. Vercel has none: its clock always starts at PR open.
TRIGGERS = {
    "coderabbit": re.compile(r"(?<![\w@])@coderabbitai[ \t]+(?:full[ \t]+)?review\b", re.I),
    "bugbot":     re.compile(r"(?<![\w@])@cursor[ \t]+review\b", re.I),
    "codeant":    re.compile(r"(?<![\w@])@codeant-ai[ \t]+review\b", re.I),
    "graphite":   re.compile(r"(?<![\w@])@graphite-app[ \t]+re-review\b", re.I),
    "greptile":   _GREPTILE_RE,
}


class LedgerError(Exception):
    """A value-field input could not be read; the ledger run fails closed."""


def _as_list(value):
    return value if isinstance(value, list) else []


def _text(value):
    return value if isinstance(value, str) else ""


def is_user_reply(comment):
    """A reply that may decide a verdict: a `User` account, never a bot login."""
    login = _text(comment.get("user"))
    return comment.get("user_type") == "User" and not login.lower().endswith("[bot]")


def parse_bodies(items, lib_dir=None):
    """Run the shared parser over many bodies in ONE jq call.

    items: [{"repo": "owner/name", "body": str}]. Returns, per item and in
    order, {"stripped": <body without quoted lines>, "refs": [issue numbers]}.
    Any failure raises LedgerError: value fields computed without the parser
    would silently read every deferral as unanswered."""
    if not items:
        return []
    lib_dir = lib_dir or os.path.dirname(os.path.abspath(__file__))
    if not os.path.isfile(os.path.join(lib_dir, DEFERRED_REFS_MODULE)):
        raise LedgerError("%s not found beside review_ledger.py in %s"
                          % (DEFERRED_REFS_MODULE, lib_dir))
    program = ('include "deferred-refs"; map(. as $i | '
               '{stripped: ($i.body | strip_quoted_lines), refs: ($i.body | deferred_refs($i.repo))})')
    try:
        proc = subprocess.run(["jq", "-c", "-L", lib_dir, program], input=json.dumps(items),
                              capture_output=True, encoding="utf-8")
    except OSError as exc:
        raise LedgerError("could not run jq for the follow-up link parser: %s" % exc)
    if proc.returncode != 0:
        raise LedgerError("jq (follow-up link parser) failed (rc=%d): %s"
                          % (proc.returncode, proc.stderr.strip()[:400]))
    try:
        parsed = json.loads(proc.stdout)
    except ValueError:
        raise LedgerError("jq (follow-up link parser) returned unparseable JSON")
    if (not isinstance(parsed, list) or len(parsed) != len(items)
            or not all(isinstance(p, dict) and isinstance(p.get("stripped"), str)
                       and isinstance(p.get("refs"), list) for p in parsed)):
        raise LedgerError("jq (follow-up link parser) returned an unexpected shape")
    return parsed


def parse_marker(inner):
    """The fields of one marker's inside text, or None when its verdict is unknown.

    Returns {"verdict", "defect": "real"|"not"|None, "agent": str|None}. Only the
    verdict is required; an unknown `defect` value reads as not-real, and an
    agent name outside a conservative token shape reads as unnamed."""
    fields = inner.split()
    if not fields or fields[0].lower() not in VERDICTS:
        return None
    marker = {"verdict": fields[0].lower(), "defect": None, "agent": None}
    for field in fields[1:]:
        key, _, value = field.partition("=")
        key = key.lower()
        if key == "defect":
            marker["defect"] = value.lower() if value.lower() in ("real", "not") else None
        elif key == "agent":
            marker["agent"] = value if _AGENT_RE.fullmatch(value) else None
    return marker


def classify_reply(stripped, refs):
    """(wording verdict or None, marker or None, ignored marker count) for one
    reply. `stripped` already has its quoted lines removed; `refs` is the shared
    parser's issue numbers for it."""
    fence_free = _FENCED_RE.sub("\n", stripped)
    code_free = _CODE_SPAN_RE.sub(" ", fence_free)
    marker = None
    ignored = 0
    for m in _MARKER_RE.finditer(code_free):
        parsed = parse_marker(m.group(1))
        if parsed is None:
            ignored += 1
        else:
            marker = parsed   # the last marker in a reply is its final word
    # Wording shown in a fenced block is an example, not a report, so both
    # wording checks read the fence-free text. Inline code spans stay readable:
    # the house form is ``Fixed in `abc1234` ``, whose SHA a span strip would
    # erase.
    if _DECLINED_RE.match(fence_free):
        wording = "declined"
    elif _FIXED_RE.search(fence_free):
        wording = "fixed"
    elif refs:
        wording = "deferred"
    else:
        wording = None
    return wording, marker, ignored


def classify_thread(replies):
    """{"verdict", "real_defect", "agent"} for one thread from its classified
    replies, oldest first: [(wording, marker), ...]."""
    markers = [marker for _, marker in replies if marker]
    if markers:
        last = markers[-1]
        return {"verdict": last["verdict"], "real_defect": last["defect"] == "real",
                "agent": last["agent"]}
    worded = [wording for wording, _ in replies if wording]
    if worded:
        return {"verdict": worded[-1], "real_defect": False, "agent": None}
    return {"verdict": "unanswered", "real_defect": False, "agent": None}


def _empty_tally():
    return {"findings": 0, "valid": 0, "real_defects": 0, "declined": 0,
            "unanswered": 0, "samples": []}


def _minutes(delta):
    """A timedelta as exact minutes (Fraction), so a median is never a float sum."""
    micros = (delta.days * 86400 + delta.seconds) * 10 ** 6 + delta.microseconds
    return Fraction(micros, 60 * 10 ** 6)


def measure_value(prs, repo, login_to_key, tool_keys, lib_dir=None):
    """Per-tool verdict tallies and response-time samples for one repo's PRs.

    prs: measure.sh's normalized PRs; each may carry `threads`
    ([{"comments": [{"user", "user_type", "body", "created_at"}],
    "comments_truncated"}]) and `created_at`. Returns (tallies, notes), where
    tallies[key] = {"findings", "valid", "real_defects", "declined",
    "unanswered", "samples": [Fraction minutes]} for every key in tool_keys."""
    tallies = {key: _empty_tally() for key in tool_keys}
    items = []
    threads = []      # (tool key, [item index of each qualifying reply])
    pr_triggers = []  # per PR: [(item index, created_at)]
    truncated = 0
    for pr in prs:
        for thread in _as_list(pr.get("threads")):
            if not isinstance(thread, dict):
                continue
            comments = _as_list(thread.get("comments"))
            # The first comment IS the finding. One that is missing or
            # malformed leaves the thread unattributable — never promote a
            # reply to finding.
            if not comments or not isinstance(comments[0], dict):
                continue
            key = login_to_key.get(_text(comments[0].get("user")))
            if key not in tallies:
                continue   # a human's own thread, or a tool outside the stack
            if thread.get("comments_truncated") is True:
                truncated += 1
            indexes = []
            for comment in comments[1:]:
                if isinstance(comment, dict) and is_user_reply(comment):
                    indexes.append(len(items))
                    items.append({"repo": repo, "body": _text(comment.get("body"))})
            threads.append((key, indexes))
        candidates = []
        for comment in _as_list(pr.get("issue_comments")):
            if not isinstance(comment, dict):
                continue
            login = _text(comment.get("user"))
            body = _text(comment.get("body"))
            # A bot's comment never triggers a review (BugBot ignores them, and
            # a tool's own footer names its handle); `@` is a cheap pre-filter.
            if not login or login.lower().endswith("[bot]") or "@" not in body:
                continue
            candidates.append((len(items), comment.get("created_at")))
            items.append({"repo": repo, "body": body})
        pr_triggers.append(candidates)

    parsed = parse_bodies(items, lib_dir)
    ignored = 0
    for key, indexes in threads:
        replies = []
        for i in indexes:
            wording, marker, bad = classify_reply(parsed[i]["stripped"], parsed[i]["refs"])
            ignored += bad
            replies.append((wording, marker))
        verdict = classify_thread(replies)
        tally = tallies[key]
        tally["findings"] += 1
        if verdict["verdict"] in ("fixed", "deferred"):
            tally["valid"] += 1
        elif verdict["verdict"] == "declined":
            tally["declined"] += 1
        else:
            tally["unanswered"] += 1
        if verdict["real_defect"]:
            tally["real_defects"] += 1

    untimed = 0
    key_logins = {login: key for login, key in login_to_key.items() if key in tallies}
    for pr, candidates in zip(prs, pr_triggers):
        triggers = {key: [] for key in TRIGGERS}
        for i, created in candidates:
            at = _parse_ts(created)
            if at is None:
                continue
            for key, rx in TRIGGERS.items():
                if rx.search(parsed[i]["stripped"]):
                    triggers[key].append(at)
        responded = {}
        undated = set()   # tools with a response on this PR that carries no timestamp
        for field, ts_key in (("reviews", "submitted_at"), ("pr_comments", "created_at"),
                              ("issue_comments", "created_at")):
            for event in _as_list(pr.get(field)):
                key = key_logins.get(_text(event.get("user"))) if isinstance(event, dict) else None
                if key is None:
                    continue
                at = _parse_ts(event.get(ts_key))
                responded.setdefault(key, [])
                if at is None:
                    undated.add(key)
                else:
                    responded[key].append(at)
        opened = _parse_ts(pr.get("created_at"))
        for key, times in responded.items():
            # An undated response may have been the first one, so the earliest
            # DATED response is not known to be the first: time nothing on
            # this PR for that tool rather than let a later one stand in.
            if not times or key in undated:
                untimed += 1
                continue
            first = min(times)
            asked = [t for t in triggers.get(key, []) if t <= first]
            start = min(asked) if asked else opened
            if start is None or start > first:
                untimed += 1
                continue
            tallies[key]["samples"].append(_minutes(first - start))

    notes = []
    if ignored:
        notes.append("%d review-verdict marker(s) named no known verdict (fixed, deferred, "
                     "declined) and were ignored; those replies were read by their wording."
                     % ignored)
    if truncated:
        notes.append("%d review thread(s) carried more than 100 comments; replies past the "
                     "100th were not read, so their verdicts may be understated." % truncated)
    if untimed:
        notes.append("%d tool response(s) could not be timed (a response on the PR with no "
                     "timestamp, so its first response is unknown, or neither a PR open time "
                     "nor a preceding trigger to start from); median_response_min leaves "
                     "them out." % untimed)
    return tallies, notes


def pool_tallies(tallies):
    """One tally from several repos' tallies for the same tool."""
    pooled = _empty_tally()
    for tally in tallies:
        for field in ("findings", "valid", "real_defects", "declined", "unanswered"):
            pooled[field] += tally[field]
        pooled["samples"].extend(tally["samples"])
    return pooled


def _round_half_up(value, places):
    """An exact Fraction rounded half-up to `places` decimals, as a JSON float."""
    exact = Decimal(value.numerator) / Decimal(value.denominator)
    return float(exact.quantize(Decimal(1).scaleb(-places), rounding=ROUND_HALF_UP))


def cost_per_real_defect(spend, real_defects):
    """spend (Decimal|None) / real defects, in cents; None when either is
    missing or zero — a receipt floor of 0.00 per defect would read as free."""
    if spend is None or spend == 0 or not real_defects:
        return None
    return cents(Decimal(spend) / Decimal(int(real_defects)))


def value_fields(tally, spend):
    """The per-tool value fields for one tally and that tool's spend (Decimal|None)."""
    valid = tally["valid"]
    declined = tally["declined"]
    samples = tally["samples"]
    return {
        "findings": tally["findings"],
        "valid": valid,
        "real_defects": tally["real_defects"],
        "declined": declined,
        "unanswered": tally["unanswered"],
        # Unanswered findings are not in the denominator: no verdict is not a no.
        "precision": (_round_half_up(Fraction(valid, valid + declined), 3)
                      if valid + declined else None),
        "cost_per_real_defect_usd": to_number(cost_per_real_defect(spend, tally["real_defects"])),
        "median_response_min": (_round_half_up(Fraction(statistics.median(samples)), 1)
                                if samples else None),
    }
