#!/usr/bin/env python3
"""Substantive-plan filter for CodeRabbit issue comments (issue #541).

Reads `gh issue view <N> --json comments` JSON on stdin and prints the body
of the LATEST substantive CodeRabbit plan comment, or nothing when no such
comment exists. Invoked by cr-plan.sh; unit tests live in
tests/test_cr_plan_filter.py.

Substance gates, in order (each is load-bearing for a different case):
  1. Enrichment marker — a body that OPENS with CodeRabbit's own
     "<!-- This is an auto-generated issue plan by CodeRabbit -->" marker is
     the enrichment container, never a plan; real plans open with the
     "auto-generated reply" marker instead. Keying off CR's machine-facing
     marker keeps the reject robust even if CR rewords its human-facing
     summaries or adds headings to the enrichment layout. Anchored to the
     start of the body so a real plan QUOTING the marker in prose (observed
     on issue #541) is unaffected.
  2. Ack reject — "Actions performed …" replies are never plans, whatever
     their length or structure.
  3. Strip-then-measure — after removing non-plan boilerplate (HTML
     comments; <details> blocks whose <summary> names Related PRs /
     Issue Planner / Issue enrichment; horizontal-rule lines; the
     "💬 Have feedback …" footer), the remainder must exceed MIN_PLAN_CHARS
     AND show plan structure (a markdown heading or a numbered step line).
     This catches boilerplate-shaped bodies that lack the marker, e.g. a
     Related-PRs block pasted into an otherwise thin comment.

Together these reject CodeRabbit's issue-enrichment beta comments (Related
PRs block + "Create Plan" checkbox offer + open-beta note: >200 chars but
zero plan content — the issue #540/#541 false positive) while keeping real
plans such as the "## Coding Plan" reply format (e.g. issue #452).

Usage: cr-plan-filter.py [comments.json]
  Reads the JSON from the given file, or from stdin when no path is given
  (cr-plan.sh stages gh output to a temp file — the ac-checkboxes.sh pattern —
  so gh failures and filter failures surface separately).

Exit codes:
  0  ran cleanly (empty stdout = no substantive plan found)
  2  invalid input (unreadable file, or not a JSON object with a comments array)
"""

from __future__ import annotations

import json
import re
import sys

# Issue comments use the bare login — no [bot] suffix (see issue-planning.md).
CR_LOGIN = "coderabbitai"

# Minimum characters of stripped content for a comment to count as a plan.
MIN_PLAN_CHARS = 200

# CodeRabbit's machine-facing discriminator: enrichment containers open with
# this marker; real plans open with "auto-generated reply" instead. Anchored
# to the body start (re.match) so plans that merely QUOTE the marker later in
# prose are unaffected.
ENRICHMENT_MARKER_RE = re.compile(
    r"\s*<!--\s*This is an auto-generated issue plan by CodeRabbit\b",
    re.IGNORECASE,
)

# Ack replies ("Actions performed — Full review triggered ...") are never
# plans. Kept even though most acks also fail the structure gate: a long,
# numbered multi-action ack would pass structure, and this preserves the
# pre-#541 filter's documented behavior.
ACK_RE = re.compile(r"^\s*actions performed\b", re.IGNORECASE)

HTML_COMMENT_RE = re.compile(r"<!--.*?-->", re.DOTALL)

# <details> blocks that carry enrichment/planner boilerplate rather than plan
# content. Both tempered dots forbid crossing another summary/details tag:
# the <summary> part keeps the keyword search inside a single summary tag (a
# preceding non-noise block is never consumed because a noise block follows
# it), and the tail stops at the block's own </details> without ever crossing
# a nested or subsequent details tag — so a malformed/unclosed or
# nested-details block simply doesn't match (fail-keep; the length+structure
# gate still decides) instead of over-consuming or rescanning to end-of-input
# per opening (quadratic on large bodies).
NOISE_SUMMARY_KEYWORDS = r"Related PRs|Issue Planner|Issue enrichment"
NOISE_DETAILS_RE = re.compile(
    r"<details[^>]*>\s*<summary[^>]*>(?:(?!</?(?:summary|details)\b).)*?"
    r"(?:" + NOISE_SUMMARY_KEYWORDS + r")"
    r"(?:(?!<details\b|</details).)*?</details>",
    re.DOTALL | re.IGNORECASE,
)

HR_LINE_RE = re.compile(r"^[ \t]*(?:-{3,}|\*{3,}|_{3,})[ \t]*$", re.MULTILINE)
FEEDBACK_LINE_RE = re.compile(r"^[ \t]*💬.*$", re.MULTILINE)

# Plan structure: an ATX heading ("## Coding Plan") or a numbered step line.
STRUCTURE_RE = re.compile(r"^[ \t]{0,3}(?:#{1,6}\s+\S|\d+[.)]\s+\S)", re.MULTILINE)


def stripped_core(body: str) -> str:
    """Remove boilerplate that must not count toward plan substance."""
    core = HTML_COMMENT_RE.sub("", body)
    core = NOISE_DETAILS_RE.sub("", core)
    core = HR_LINE_RE.sub("", core)
    core = FEEDBACK_LINE_RE.sub("", core)
    return core.strip()


def is_substantive(body: str) -> bool:
    """True when the body carries actual plan content, not just boilerplate."""
    if ENRICHMENT_MARKER_RE.match(body):
        return False
    if ACK_RE.match(body):
        return False
    core = stripped_core(body)
    return len(core) > MIN_PLAN_CHARS and STRUCTURE_RE.search(core) is not None


def latest_plan(comments: list) -> str | None:
    """Return the body of the last substantive CodeRabbit comment, if any."""
    # Newest-first with short-circuit: only the latest substantive comment
    # matters, and CodeRabbit bodies can be 50KB+ (gh returns comments
    # oldest-first), so don't re-filter the whole history on every poll tick.
    for comment in reversed(comments):
        if not isinstance(comment, dict):
            continue
        if ((comment.get("author") or {}).get("login")) != CR_LOGIN:
            continue
        body = comment.get("body") or ""
        if is_substantive(body):
            return body
    return None


USAGE = "usage: cr-plan-filter.py [comments.json]  (reads stdin when no path is given)"


def main(argv: list) -> int:
    # --help is part of the catalog contract for every script in
    # .claude/scripts/, so it must not be read as an input filename.
    if any(arg in ("-h", "--help") for arg in argv[1:]):
        print(USAGE)
        return 0
    if len(argv) > 2:
        print(USAGE, file=sys.stderr)
        return 2
    source = argv[1] if len(argv) == 2 else None
    try:
        if source is not None:
            with open(source, encoding="utf-8") as fh:
                data = json.load(fh)
        else:
            data = json.load(sys.stdin)
    except OSError as exc:
        print(
            f"cr-plan-filter.py: cannot read {source if source is not None else 'stdin'}: {exc}",
            file=sys.stderr,
        )
        return 2
    except (json.JSONDecodeError, UnicodeDecodeError) as exc:
        print(f"cr-plan-filter.py: invalid JSON input: {exc}", file=sys.stderr)
        return 2
    if not isinstance(data, dict):
        print(
            "cr-plan-filter.py: expected a JSON object with a 'comments' array",
            file=sys.stderr,
        )
        return 2
    comments = data.get("comments") or []
    if not isinstance(comments, list):
        print("cr-plan-filter.py: 'comments' is not an array", file=sys.stderr)
        return 2
    plan = latest_plan(comments)
    if plan is not None:
        print(plan)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
