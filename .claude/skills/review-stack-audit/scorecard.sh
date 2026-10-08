#!/usr/bin/env bash
# scorecard.sh — Render the value-per-dollar scorecard for /review-stack-audit's report.
#
# PURPOSE
#   Issue #1811 (increment 4/5 of #1747). measure.sh records, per review tool
#   and across repos, what each one cost and what each one caught. This turns
#   that snapshot into the three pieces of report content Step 7 embeds:
#
#     window   one line: the 30-day study window, or `study window: not started`
#     value    `## Value per dollar` — tools ranked by cost per real defect
#     claims   `## Vendor claims vs observed` — each vendor's published claim
#              beside our observed precision and cost per real defect
#
#   It is pure rendering: Markdown on stdout, no gh call, no file written, no
#   verdict. The tables are report content, never drift findings, so nothing
#   here can make the audit file an issue.
#
# USAGE
#   scorecard.sh --snapshot <file> [--claims <file>] [--state-dir <dir>]
#                [--part all|window|value|claims]
#   scorecard.sh --part window [--state-dir <dir>]
#   scorecard.sh --help | -h
#
#   --snapshot   A measure.sh --json snapshot. Required for every part but
#                `window`.
#   --claims     The Markdown page holding the `review-stack-claims` block.
#                Default: this checkout's
#                .claude/reference/ai-review-vendor-claims.md, then the
#                published copies. If none resolves, the claims part prints a
#                one-line caveat instead of a table.
#   --state-dir  Where snapshot-*.json files live. Default:
#                ~/.claude/review-stack-audit.
#   --part       Which piece to print (default `all`: window, value, claims,
#                blank-line separated).
#
# VALUE PER DOLLAR (--part value)
#   One row per tool in the snapshot's top-level `tools[]` — the cross-repo
#   total on a multi-repo run — with spend (and its `spend_source` label), real
#   defects, cost per real defect, precision, and sole-source PRs
#   (`sole_provider_on`). Ranking:
#     1. tools with a cost per real defect, lowest cost first;
#     2. tools with known spend but no cost (no real defect, or $0 spend),
#        spend still shown;
#     3. tools whose spend is unknown (null), last.
#   Precision breaks ties inside each group (higher first, null last), then the
#   tool key. A multi-repo snapshot adds a collapsed per-repo table ranked the
#   same way. A null renders as `—`, never as `0`; a real zero renders `0`.
#   A snapshot without the ledger fields (measured without --ledger, --repos,
#   or --all-repos) prints one line saying so instead of a table of dashes.
#
# CLAIMS VS OBSERVED (--part claims)
#   Reads ONLY the fenced block tagged `review-stack-claims` (schema
#   `review-stack-claims/v1`), through review_ledger.py's fence parser — the
#   same one that reads the pricing matrix's rates block. A missing, duplicated,
#   unterminated, or malformed block is refused whole: one caveat line, no
#   partial table. One row per recorded claim, joined to the snapshot on
#   `tool_key`; then one `no published claim` row for every snapshot tool no
#   claim names, citing the page's own `page_url` and `retrieved`, so every row
#   carries a source URL and a date.
#
# STUDY WINDOW (--part window)
#   Start: the UTC date of `generated_at` on the earliest ledger-mode snapshot
#   (a tool carries `spend_source`) among <state-dir>/snapshot-*.json. End:
#   start + 30 days. No ledger snapshot: `study window: not started`. Files that
#   cannot be read or parsed are skipped and counted on the line; an unreadable
#   state directory reads `study window: unknown`, never `not started`.
#
# EXIT STATUS
#   0  Rendered. A part that cannot render prints a one-line caveat in place.
#   1  The snapshot is missing, unreadable, or not a measure.sh snapshot.
#   2  Usage error.
#
# EXAMPLES
#   .claude/skills/review-stack-audit/scorecard.sh --snapshot ~/.claude/review-stack-audit/snapshot-2026-10.json
#   .claude/skills/review-stack-audit/scorecard.sh --part window

set -euo pipefail
printf '%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$(basename "$0")" "${*//$'\n'/ }" 2>/dev/null >> "${HOME:-/tmp}/.claude/script-usage.log" || true

print_help() {
  awk 'NR == 1 { next } /^$/ { exit } { sub(/^# ?/, ""); print }' "$0"
}

usage_error() {
  echo "scorecard.sh: $1" >&2
  echo "Run with --help for usage." >&2
  exit 2
}

SNAPSHOT=""
CLAIMS=""
STATE_DIR=""
STATE_DIR_SET=0
PART="all"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) print_help; exit 0 ;;
    --snapshot)
      [[ $# -ge 2 && -n "$2" ]] || usage_error "--snapshot requires a value"
      SNAPSHOT="$2"; shift 2 ;;
    --snapshot=*)
      SNAPSHOT="${1#--snapshot=}"; [[ -n "$SNAPSHOT" ]] || usage_error "--snapshot value cannot be empty"; shift ;;
    --claims)
      [[ $# -ge 2 && -n "$2" ]] || usage_error "--claims requires a value"
      CLAIMS="$2"; shift 2 ;;
    --claims=*)
      CLAIMS="${1#--claims=}"; [[ -n "$CLAIMS" ]] || usage_error "--claims value cannot be empty"; shift ;;
    --state-dir)
      [[ $# -ge 2 && -n "$2" ]] || usage_error "--state-dir requires a value"
      STATE_DIR="$2"; STATE_DIR_SET=1; shift 2 ;;
    --state-dir=*)
      STATE_DIR="${1#--state-dir=}"; [[ -n "$STATE_DIR" ]] || usage_error "--state-dir value cannot be empty"
      STATE_DIR_SET=1; shift ;;
    --part)
      [[ $# -ge 2 && -n "$2" ]] || usage_error "--part requires a value"
      PART="$2"; shift 2 ;;
    --part=*)
      PART="${1#--part=}"; [[ -n "$PART" ]] || usage_error "--part value cannot be empty"; shift ;;
    --) shift; break ;;
    -*) usage_error "unknown flag: $1" ;;
    *)  usage_error "unexpected positional argument: $1" ;;
  esac
done

[[ $# -eq 0 ]] || usage_error "unexpected positional argument: $1"

case "$PART" in
  all|window|value|claims) ;;
  *) usage_error "--part must be one of all, window, value, claims (got '$PART')" ;;
esac
[[ "$PART" == "window" || -n "$SNAPSHOT" ]] || usage_error "--snapshot is required for --part $PART"
if [[ "$STATE_DIR_SET" -eq 0 && -n "${HOME:-}" ]]; then
  STATE_DIR="$HOME/.claude/review-stack-audit"
fi

# This checkout's own .claude/ first (`cd -P` resolves the published
# ~/.claude/skills symlink to the worktree), then the published locations —
# measure.sh's order, so the renderer and the measurement read one checkout.
_claude_dir="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd)" || _claude_dir=""
LIB_DIR=""
if [[ "$PART" == "all" || "$PART" == "claims" ]]; then
  for _c in \
    ${_claude_dir:+"$_claude_dir/scripts/lib"} \
    ${HOME:+"$HOME/.claude/skills-worktree/.claude/scripts/lib"} \
    ${HOME:+"$HOME/.claude/scripts/lib"} \
    ".claude/scripts/lib"; do
    if [[ -r "$_c/review_ledger.py" ]]; then LIB_DIR="$_c"; break; fi
  done
  [[ -n "$LIB_DIR" ]] \
    || echo "DEGRADED: review_ledger.py not found (checked this checkout's .claude/scripts/lib and all three published paths) — vendor claims table unavailable, continuing without it" >&2
  if [[ -z "$CLAIMS" ]]; then
    for _c in \
      ${_claude_dir:+"$_claude_dir/reference/ai-review-vendor-claims.md"} \
      ${HOME:+"$HOME/.claude/skills-worktree/.claude/reference/ai-review-vendor-claims.md"} \
      ${HOME:+"$HOME/.claude/reference/ai-review-vendor-claims.md"} \
      ".claude/reference/ai-review-vendor-claims.md"; do
      if [[ -r "$_c" && -f "$_c" ]]; then CLAIMS="$_c"; break; fi
    done
    [[ -n "$CLAIMS" ]] \
      || echo "DEGRADED: ai-review-vendor-claims.md not found (checked this checkout's .claude/reference and all three published paths) — vendor claims table unavailable, continuing without it" >&2
  fi
fi

SCORECARD_SNAPSHOT="$SNAPSHOT" \
SCORECARD_CLAIMS="$CLAIMS" \
SCORECARD_STATE_DIR="$STATE_DIR" \
SCORECARD_PART="$PART" \
SCORECARD_LIB_DIR="$LIB_DIR" \
python3 - <<'PY'
import fnmatch
import json
import math
import os
import re
import sys
# timezone.utc rather than datetime.UTC: this must run on macOS system python3
# (3.9), where datetime.UTC does not exist.
from datetime import datetime, timedelta, timezone
from decimal import Decimal, ROUND_HALF_UP

# A renderer writes nothing — not even bytecode beside the library it imports.
sys.dont_write_bytecode = True

DASH = "—"
STUDY_DAYS = 30
CLAIMS_TAG = "review-stack-claims"
CLAIMS_SCHEMA = "review-stack-claims/v1"
CLAIM_FIELDS = ("vendor", "claim", "metric", "benchmark", "authorship", "source_url",
                "retrieved", "status")
STATUSES = ("verified", "unverified")
DATE_RE = re.compile(r"^[0-9]{4}-[0-9]{2}-[0-9]{2}$")


def is_date(value):
    """A real calendar date written YYYY-MM-DD. The layout alone is not enough:
    `2026-99-99` matches it and would print as a retrieval date nobody had."""
    if not (isinstance(value, str) and DATE_RE.match(value)):
        return False
    try:
        datetime.strptime(value, "%Y-%m-%d")
    except ValueError:
        return False
    return True

snapshot_path = os.environ.get("SCORECARD_SNAPSHOT", "")
claims_path = os.environ.get("SCORECARD_CLAIMS", "")
state_dir = os.environ.get("SCORECARD_STATE_DIR", "")
part = os.environ.get("SCORECARD_PART", "all")
lib_dir = os.environ.get("SCORECARD_LIB_DIR", "")


def fail(msg):
    print("scorecard.sh: %s" % msg, file=sys.stderr)
    sys.exit(1)


# --- formatting: one rule for "no figure" -------------------------------------

def number(value):
    """A finite JSON number as Decimal; None for null and anything not a number.

    A bool is not a number here even though Python says it is an int, and NaN or
    Infinity is no figure at all — every one of them renders `—`, never `0`.
    """
    if value is None or isinstance(value, bool):
        return None
    if isinstance(value, int):
        return Decimal(value)
    if isinstance(value, float) and math.isfinite(value):
        return Decimal(repr(value))
    return None


def money(value):
    d = number(value)
    if d is None:
        return DASH
    return "$" + "{:,.2f}".format(d.quantize(Decimal("0.01"), rounding=ROUND_HALF_UP))


def pct(value):
    d = number(value)
    if d is None:
        return DASH
    return "%s%%" % (d * 100).quantize(Decimal("0.1"), rounding=ROUND_HALF_UP)


def count(value):
    d = number(value)
    if d is None or d != d.to_integral_value():
        return DASH
    return str(int(d))


def cell(text):
    """One Markdown table cell: no line breaks, no unescaped pipe."""
    return str(text).replace("\r", " ").replace("\n", " ").replace("|", "\\|")


def row(cells):
    return "| " + " | ".join(cell(c) for c in cells) + " |"


def label(tool):
    src = tool.get("spend_source")
    return src if isinstance(src, str) and src else "unlabelled"


def tool_name(tool):
    name = tool.get("name")
    if isinstance(name, str) and name:
        return name
    key = tool.get("key")
    return key if isinstance(key, str) and key else "(unnamed tool)"


def tool_list(doc):
    tools = doc.get("tools") if isinstance(doc, dict) else None
    return [t for t in tools if isinstance(t, dict)] if isinstance(tools, list) else []


def is_ledger(doc):
    """A ledger-mode snapshot: its tools carry the spend label (#1809)."""
    return any("spend_source" in t for t in tool_list(doc))


# --- value per dollar ---------------------------------------------------------

def rank_key(tool):
    spend = number(tool.get("spend_usd"))
    cost = number(tool.get("cost_per_real_defect_usd"))
    prec = number(tool.get("precision"))
    if spend is None:
        group = 2          # unknown spend: last, whatever else it found
    elif cost is None:
        group = 1          # paid (or free), but no cost per real defect
    else:
        group = 0
    key = tool.get("key")
    return (group, cost if group == 0 else Decimal(0),
            prec is None, -prec if prec is not None else Decimal(0),
            key if isinstance(key, str) else "")


def ranked(tools):
    return sorted(tools, key=rank_key)


VALUE_HEADER = ["Rank", "Tool", "Spend", "Real defects", "Cost / real defect",
                "Precision", "Sole-source PRs"]
VALUE_ALIGN = "|---:|---|---:|---:|---:|---:|---:|"


def value_cells(rank, tool):
    return [rank, tool_name(tool), "%s (%s)" % (money(tool.get("spend_usd")), label(tool)),
            count(tool.get("real_defects")), money(tool.get("cost_per_real_defect_usd")),
            pct(tool.get("precision")), count(tool.get("sole_provider_on"))]


def render_value(doc):
    out = ["## Value per dollar", ""]
    if not is_ledger(doc):
        out.append("_Value per dollar unavailable: this snapshot was measured without the "
                   "spend ledger, so it has no spend or real-defect figures. Measure "
                   "with `--ledger` (`--repos` and `--all-repos` imply it)._")
        return out
    tools = tool_list(doc)
    repos = doc.get("repos")
    win = doc.get("window") if isinstance(doc.get("window"), dict) else {}
    scope = ("across %d repos (%s)" % (len(repos), ", ".join(str(r) for r in repos))
             if isinstance(repos, list) and repos else "for %s" % (doc.get("repo") or "one repo"))
    out.append("Each tool's total %s, window %s → %s." % (
        scope, win.get("since") or DASH, win.get("until") or DASH))
    out.append("")
    out.append(row(VALUE_HEADER))
    out.append(VALUE_ALIGN)
    for i, t in enumerate(ranked(tools), 1):
        out.append(row(value_cells(i, t)))
    out.append("")
    out.append("Ranked by cost per real defect, lowest first; precision breaks ties. A tool "
               "with spend but no real defect follows, its spend still shown; a tool whose "
               "spend is unknown comes last. `%s` is no figure, never zero." % DASH)
    out.append("Spend labels: `receipt` is CodeRabbit's own charge lines (a floor), "
               "`estimate` a count times a unit rate, `flat` a monthly fee prorated to the "
               "window, `none` no figure. The vendor dashboard, not this table, is the bill.")
    per_repo = doc.get("per_repo")
    if isinstance(per_repo, list) and per_repo:
        out += ["", "<details><summary>By repo</summary>", "",
                row(["Repo"] + VALUE_HEADER), "|---" + VALUE_ALIGN]
        for entry in per_repo:
            if not isinstance(entry, dict):
                continue
            for i, t in enumerate(ranked(tool_list(entry)), 1):
                out.append(row([entry.get("repo") or DASH] + value_cells(i, t)))
        out += ["", "</details>"]
    return out


# --- claims vs observed -------------------------------------------------------

def load_claims():
    """(doc, None) for a valid block, else (None, why). Refused whole, never partly."""
    if not lib_dir:
        return None, "review_ledger.py (its fence parser) not found"
    if not claims_path:
        return None, "the claims page (ai-review-vendor-claims.md) not found"
    sys.path.insert(0, lib_dir)
    try:
        import review_ledger
    except Exception as exc:  # any import-time fault refuses the table, visibly
        return None, "could not import review_ledger.py: %s" % exc
    try:
        with open(claims_path, encoding="utf-8") as fh:
            text = fh.read()
    except (OSError, UnicodeDecodeError) as exc:
        return None, "cannot read %s: %s" % (claims_path, exc)
    bodies, err = review_ledger.tagged_fences(text, CLAIMS_TAG)
    if err:
        return None, err
    if len(bodies) != 1:
        return None, "%d `%s` blocks in %s — exactly one is required" % (
            len(bodies), CLAIMS_TAG, claims_path)
    try:
        doc = json.loads(bodies[0])
    except ValueError as exc:
        return None, "the `%s` block is not valid JSON: %s" % (CLAIMS_TAG, exc)
    if not isinstance(doc, dict) or doc.get("schema") != CLAIMS_SCHEMA:
        return None, "the `%s` block's schema is not %r" % (CLAIMS_TAG, CLAIMS_SCHEMA)
    if not is_date(doc.get("retrieved")):
        return None, "the `%s` block needs `retrieved` as YYYY-MM-DD" % CLAIMS_TAG
    if not (isinstance(doc.get("page_url"), str) and doc["page_url"].startswith("https://")):
        return None, "the `%s` block needs an https `page_url`" % CLAIMS_TAG
    claims = doc.get("claims")
    if not isinstance(claims, list):
        return None, "the `%s` block's `claims` must be an array" % CLAIMS_TAG
    for i, c in enumerate(claims):
        if not isinstance(c, dict):
            return None, "claims[%d] is not an object" % i
        for field in CLAIM_FIELDS:
            if not isinstance(c.get(field), str) or not c[field].strip():
                return None, "claims[%d] needs a non-empty `%s`" % (i, field)
        if not c["source_url"].startswith("https://"):
            return None, "claims[%d] `source_url` must be an https URL" % i
        if not is_date(c["retrieved"]):
            return None, "claims[%d] `retrieved` must be YYYY-MM-DD" % i
        if c["status"] not in STATUSES:
            return None, "claims[%d] `status` must be one of %s" % (i, ", ".join(STATUSES))
        if "tool_key" not in c or not (c["tool_key"] is None or
                                       (isinstance(c["tool_key"], str) and c["tool_key"])):
            return None, "claims[%d] needs `tool_key`: a measure.sh tool key, or null" % i
    return doc, None


def render_claims(doc):
    out = ["## Vendor claims vs observed", ""]
    claims_doc, why = load_claims()
    if claims_doc is None:
        out.append("_Vendor claims unavailable: %s._" % why)
        return out
    tools = tool_list(doc)
    by_key = {t["key"]: t for t in tools if isinstance(t.get("key"), str)}
    out.append("Published claims from `ai-review-vendor-claims.md` (verified %s) beside "
               "this run's observed figures. **Not comparable:** the claims come from small, "
               "partly vendor-authored benchmarks of injected or back-tracked bugs; ours are "
               "agent-judged verdicts on real PRs." % claims_doc["retrieved"])
    if not is_ledger(doc):
        out.append("")
        out.append("_This snapshot has no ledger fields, so every observed cell is `%s`._" % DASH)
    out += ["", row(["Vendor", "Published claim", "Metric", "Status", "Our precision",
                     "Our cost / real defect", "Source", "Retrieved"]),
            "|---|---|---|---|---:|---:|---|---|"]
    claimed = set()
    unmatched = []
    for c in claims_doc["claims"]:
        t = by_key.get(c["tool_key"]) if c["tool_key"] else None
        if c["tool_key"]:
            claimed.add(c["tool_key"])
            if t is None:
                unmatched.append(c["tool_key"])
        out.append(row([c["vendor"], c["claim"], c["metric"],
                        "%s; %s" % (c["status"], c["authorship"]),
                        pct(t.get("precision")) if t else DASH,
                        money(t.get("cost_per_real_defect_usd")) if t else DASH,
                        "<%s>" % c["source_url"], c["retrieved"]]))
    for t in tools:
        if t.get("key") in claimed:
            continue
        out.append(row([tool_name(t), "no published claim", DASH, DASH,
                        pct(t.get("precision")), money(t.get("cost_per_real_defect_usd")),
                        "<%s>" % claims_doc["page_url"], claims_doc["retrieved"]]))
    if unmatched:
        # A tool_key this snapshot does not carry: a typo, or a tool measured
        # under another key. Said aloud, because its observed cells read `—`.
        out.append("")
        out.append("_Claims whose `tool_key` matches no tool in this snapshot (observed "
                   "cells left `%s`): %s._" % (DASH, ", ".join(sorted(set(unmatched)))))
    return out


# --- study window -------------------------------------------------------------

def utc_date(value):
    if not isinstance(value, str) or not value.strip():
        return None
    text = value.strip()
    if text[-1] in "Zz":
        text = text[:-1] + "+00:00"
    try:
        stamp = datetime.fromisoformat(text)
    except ValueError:
        return None
    if stamp.tzinfo is None:
        stamp = stamp.replace(tzinfo=timezone.utc)
    return stamp.astimezone(timezone.utc).date()


def render_window():
    if not state_dir:
        return "study window: unknown (no state directory: HOME is unset and no --state-dir given)"
    # os.path.exists answers False when a permission error stops the stat, which
    # would read an inaccessible directory as "nothing yet". Only a real
    # FileNotFoundError means not started; every other failure is unknown.
    try:
        os.stat(state_dir)
    except FileNotFoundError:
        return "study window: not started"
    except OSError as exc:
        return "study window: unknown (cannot read %s: %s)" % (state_dir, exc.strerror or exc)
    try:
        names = sorted(n for n in os.listdir(state_dir) if fnmatch.fnmatch(n, "snapshot-*.json"))
    except OSError as exc:
        # An unreadable directory is a failed lookup, never "no snapshot yet".
        return "study window: unknown (cannot read %s: %s)" % (state_dir, exc.strerror or exc)
    first, skipped = None, 0
    for name in names:
        try:
            with open(os.path.join(state_dir, name), encoding="utf-8") as fh:
                doc = json.load(fh)
        except (OSError, ValueError, UnicodeDecodeError):
            skipped += 1
            continue
        if not isinstance(doc, dict):
            skipped += 1
            continue
        if not is_ledger(doc):
            continue
        day = utc_date(doc.get("generated_at"))
        if day is None:
            skipped += 1
            continue
        if first is None or day < first:
            first = day
    tail = ("; %d snapshot(s) skipped as unreadable, malformed, or undated" % skipped
            if skipped else "")
    if first is None:
        return "study window: not started" + tail
    end = first + timedelta(days=STUDY_DAYS)
    return "study window: %s → %s (%d days from the first ledger snapshot%s)" % (
        first.isoformat(), end.isoformat(), STUDY_DAYS, tail)


# --- main ---------------------------------------------------------------------

snapshot = None
if part != "window":
    try:
        with open(snapshot_path, encoding="utf-8") as fh:
            snapshot = json.load(fh)
    except (OSError, ValueError, UnicodeDecodeError) as exc:
        fail("cannot read snapshot %s: %s" % (snapshot_path, exc))
    if not isinstance(snapshot, dict) or not isinstance(snapshot.get("tools"), list):
        fail("%s is not a measure.sh snapshot (no `tools` array)" % snapshot_path)

blocks = []
if part in ("all", "window"):
    blocks.append([render_window()])
if part in ("all", "value"):
    blocks.append(render_value(snapshot))
if part in ("all", "claims"):
    blocks.append(render_claims(snapshot))
print("\n\n".join("\n".join(b) for b in blocks))
PY
