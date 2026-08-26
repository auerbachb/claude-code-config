#!/usr/bin/env bash
# measure.sh — Measure what each AI review tool actually did, for /review-stack-audit.
#
# PURPOSE
#   Emits one dated snapshot of the review stack: per tool, what it cost us to
#   keep, what limit it ran into, how much it reviewed, and how much of that was
#   value only it provided. The audit compares this against a recorded baseline
#   and files drift issues; this script reaches no verdict of its own (#1201).
#
#   It is pure measurement. It reads no decision record, decides no drift, and
#   never writes anything outside stdout.
#
# THE FOUR DIMENSIONS (issue #1201 AC1)
#   billed state    `plan_observed` — the plan tier a vendor states about
#                   itself in its own comments. Only some vendors emit one; see
#                   BILLED STATE IS A PROXY below.
#   observed caps   `cap_signals[]` — deduped per PR, each naming the tool, the
#                   kind of limit, and the PR it was observed on.
#   throughput      `prs_touched`, `review_objects`, `approved`,
#                   `changes_requested`, `issue_comments`.
#   findings value  `inline_findings`, and `sole_provider_on` — the PRs where
#                   this tool was the ONLY one to post an inline finding. That
#                   second number is the unique-value signal: a tool with high
#                   volume and zero sole-provider PRs is confirming what another
#                   tool already found.
#
# BILLED STATE IS A PROXY, NOT A MEASUREMENT
#   No vendor here exposes a billing API this script can read. What it can read
#   is (a) a plan tier a vendor volunteers in its own comment body, and (b) the
#   limit messages that appear when a plan runs out. Both are reported as
#   observations. The authoritative billed state is the `billed` field a human
#   maintains in the baseline; the audit's job is to notice when these two
#   disagree, which is exactly the D3 drift the audit exists to catch.
#
# CLASSIFIERS ARE DECLARED AND GROUNDED
#   Every cap phrase lives in the CAP_SIGNALS table below, each carrying the
#   observation that put it there. They were extracted from 4,632 real bot
#   comments on this repo's 25 most recently merged PRs, not guessed. A vendor
#   reword is therefore a one-line fix in one place.
#
#   A comment that looks limit-shaped but matches nothing declared is reported
#   in `unclassified[]` — NEVER silently counted as healthy. A stale phrase
#   table that quietly reads "active" for a capped tool would defeat the whole
#   audit, so the failure is made visible instead.
#
# USAGE
#   measure.sh [--repo owner/name] [--since YYYY-MM-DD | --days N] [--limit N]
#              [--fixture <path>] [--json | --summary]
#   measure.sh --help | -h
#
#   --repo      Repo to measure. Default: gh's current-repo inference.
#   --since     Window start, inclusive (YYYY-MM-DD). Default: --days 30.
#   --days      Window start as N days before today. Mutually exclusive
#               with --since.
#   --limit     Max merged PRs to sample in the window (default 60). The window
#               is the measurement's meaning, so a truncated sample is declared
#               in `window.truncated` rather than passed off as the whole window.
#   --fixture   Read a pre-captured bundle instead of calling gh. Same code path,
#               so tests exercise the real classifier. Shape: FIXTURE FORMAT.
#   --json      Full snapshot on stdout (DEFAULT).
#   --summary   One `tool<TAB>state<TAB>prs<TAB>findings<TAB>sole` line per tool.
#
# FIXTURE FORMAT
#   {"repo": "owner/name",
#    "prs": [{"number": 1, "merged_at": "...",
#             "reviews":        [{"user": "coderabbitai[bot]", "state": "APPROVED", "body": ""}],
#             "pr_comments":    [{"user": "coderabbitai[bot]", "body": ""}],
#             "issue_comments": [{"user": "coderabbitai[bot]", "body": ""}]}]}
#
# OUTPUT (--json)
#   {
#     "generated_at": "<ISO-8601 UTC>",
#     "repo": "owner/name",
#     "source": "github" | "fixture",
#     "window": {"since", "until", "days", "pr_count", "limit", "truncated"},
#     "tools": [{"key", "login", "observed_state", "plan_observed",
#                "prs_touched", "review_objects", "approved",
#                "changes_requested", "inline_findings", "issue_comments",
#                "sole_provider_on", "cap_signals": [...], "cap_kinds": [...]}],
#     "unclassified": [{"tool", "pr", "token", "excerpt"}],
#     "unclassified_hits": N,   # raw probe hits before (tool, token) dedup
#     "notes": [...]
#   }
#
# EXIT STATUS
#   0  Snapshot emitted.
#   1  Measurement failed (gh/network/fixture unreadable). Nothing is emitted —
#      a partial snapshot must never become the baseline a later run trusts.
#   2  Usage error.
#
# EXAMPLES
#   .claude/skills/review-stack-audit/measure.sh --days 30 --summary
#   .claude/skills/review-stack-audit/measure.sh --since 2026-06-27 | jq '.tools[]'

set -euo pipefail
printf '%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$(basename "$0")" "${*//$'\n'/ }" >> "${HOME:-/tmp}/.claude/script-usage.log" 2>/dev/null || true

print_help() {
  awk 'NR == 1 { next } /^$/ { exit } { sub(/^# ?/, ""); print }' "$0"
}

usage_error() {
  echo "measure.sh: $1" >&2
  echo "Run with --help for usage." >&2
  exit 2
}

MODE="json"
REPO=""
SINCE=""
DAYS=""
LIMIT="60"
FIXTURE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) print_help; exit 0 ;;
    --json)    MODE="json"; shift ;;
    --summary) MODE="summary"; shift ;;
    --repo)
      [[ $# -ge 2 && -n "$2" ]] || usage_error "--repo requires a value"
      REPO="$2"; shift 2 ;;
    --repo=*)
      REPO="${1#--repo=}"; [[ -n "$REPO" ]] || usage_error "--repo value cannot be empty"; shift ;;
    --since)
      [[ $# -ge 2 && -n "$2" ]] || usage_error "--since requires a value"
      SINCE="$2"; shift 2 ;;
    --since=*)
      SINCE="${1#--since=}"; [[ -n "$SINCE" ]] || usage_error "--since value cannot be empty"; shift ;;
    --days)
      [[ $# -ge 2 && -n "$2" ]] || usage_error "--days requires a value"
      DAYS="$2"; shift 2 ;;
    --days=*)
      DAYS="${1#--days=}"; [[ -n "$DAYS" ]] || usage_error "--days value cannot be empty"; shift ;;
    --limit)
      [[ $# -ge 2 && -n "$2" ]] || usage_error "--limit requires a value"
      LIMIT="$2"; shift 2 ;;
    --limit=*)
      LIMIT="${1#--limit=}"; [[ -n "$LIMIT" ]] || usage_error "--limit value cannot be empty"; shift ;;
    --fixture)
      [[ $# -ge 2 && -n "$2" ]] || usage_error "--fixture requires a value"
      FIXTURE="$2"; shift 2 ;;
    --fixture=*)
      FIXTURE="${1#--fixture=}"; [[ -n "$FIXTURE" ]] || usage_error "--fixture value cannot be empty"; shift ;;
    --) shift; break ;;
    -*) usage_error "unknown flag: $1" ;;
    *)  usage_error "unexpected positional argument: $1" ;;
  esac
done

[[ $# -eq 0 ]] || usage_error "unexpected positional argument: $1"

[[ -n "$SINCE" && -n "$DAYS" ]] && usage_error "--since and --days are mutually exclusive"
[[ -z "$DAYS"  ]] || [[ "$DAYS"  =~ ^[0-9]+$ ]] || usage_error "--days must be a non-negative integer"
# Positive, not merely non-negative: `gh pr list --limit 0` fails with its own
# opaque error, and a zero-PR "measurement" is not a window worth reporting.
[[ "$LIMIT" =~ ^[0-9]+$ ]] && [[ "$LIMIT" -gt 0 ]] || usage_error "--limit must be a positive integer"
[[ -z "$SINCE" ]] || [[ "$SINCE" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || usage_error "--since must be YYYY-MM-DD"
[[ -z "$FIXTURE" ]] || [[ -r "$FIXTURE" ]] || { echo "measure.sh: fixture not readable: $FIXTURE" >&2; exit 1; }

if [[ -z "$FIXTURE" ]]; then
  command -v gh >/dev/null 2>&1 || { echo "measure.sh: gh not found (or pass --fixture)" >&2; exit 1; }
fi
command -v python3 >/dev/null 2>&1 || { echo "measure.sh: python3 not found" >&2; exit 1; }

MEASURE_MODE="$MODE" \
MEASURE_REPO="$REPO" \
MEASURE_SINCE="$SINCE" \
MEASURE_DAYS="$DAYS" \
MEASURE_LIMIT="$LIMIT" \
MEASURE_FIXTURE="$FIXTURE" \
python3 - <<'PY'
import json
import os
import re
import subprocess
import sys
# timezone.utc rather than datetime.UTC: this must run on macOS system python3
# (3.9), where datetime.UTC does not exist.
from datetime import datetime, timedelta, timezone

mode = os.environ.get("MEASURE_MODE", "json")
repo_arg = os.environ.get("MEASURE_REPO", "")
since_arg = os.environ.get("MEASURE_SINCE", "")
days_arg = os.environ.get("MEASURE_DAYS", "")
limit = int(os.environ.get("MEASURE_LIMIT", "60"))
fixture = os.environ.get("MEASURE_FIXTURE", "")


def fail(msg):
    print("measure.sh: %s" % msg, file=sys.stderr)
    sys.exit(1)


# --- the review stack ---------------------------------------------------------
# `key` is the stable identifier the baseline and every filed drift issue use.
# A login changes far more easily than a tool's identity, so nothing downstream
# keys on the login.
TOOLS = [
    {"key": "coderabbit", "login": "coderabbitai[bot]", "name": "CodeRabbit"},
    {"key": "codeant",    "login": "codeant-ai[bot]",   "name": "CodeAnt"},
    {"key": "bugbot",     "login": "cursor[bot]",       "name": "BugBot (Cursor)"},
    {"key": "greptile",   "login": "greptile-apps[bot]", "name": "Greptile"},
    {"key": "graphite",   "login": "graphite-app[bot]", "name": "Graphite"},
    {"key": "vercel",     "login": "vercel[bot]",       "name": "Vercel Agent"},
]
LOGIN_TO_KEY = {t["login"]: t["key"] for t in TOOLS}

# --- declared cap classifiers -------------------------------------------------
# Each entry records the observation that justifies it. `pattern` is matched
# case-insensitively against the RAW comment body, so machine markers written as
# HTML comments still match.
CAP_SIGNALS = [
    # CodeRabbit meters two DIFFERENT mechanisms and says so in two different
    # places, so they carry two kinds (issue #1303). `rate_limit` means "a review
    # was refused for rate reasons"; `fair_usage` means "the refusal named the
    # Fair Usage trailing-volume policy". The two are not disjoint populations —
    # one banner routinely carries the machine marker AND the Fair Usage
    # sentence, so that PR is counted under both kinds. Reading either count as
    # the whole story is the mistake this split exists to prevent.
    {"tool": "coderabbit", "kind": "rate_limit",
     "pattern": "auto-generated comment: rate limited by coderabbit.ai",
     "note": "machine marker; 23 occurrences in the grounding sample. Usually "
             "rides alongside the Fair Usage sentence (213 of 233 capped PRs in "
             "the #1303 window), so it does not by itself distinguish the two "
             "mechanisms"},
    {"tool": "coderabbit", "kind": "rate_limit",
     "pattern": "review limit reached",
     "note": "human-visible heading accompanying the marker above"},
    # fair_usage is the trailing-7-day-volume band, distinct from the
    # per-developer per-hour burst allowance it modulates (Pro base: 5/hr).
    # Split out from rate_limit under #1303.
    #
    # ANCHORED ON THE REFUSAL CLAUSE, NOT THE POLICY NAME (#1338). The bare
    # noun phrase "Fair Usage Limits Policy" is NOT a cap signal: CodeRabbit
    # also *explains* the policy in ordinary prose, and this repo's own cap
    # documentation gets quoted back at us. PR #1292 carries a live example —
    # a 7.3 kB CodeRabbit answer reading "CodeRabbit also maintains a Fair
    # Usage Limits Policy, which may adjust review availability for accounts
    # demonstrating sustained, high-volume activity" — which the bare phrase
    # counted as a cap. Both patterns below instead quote the clause CodeRabbit
    # writes only when it is actually declining a review ("...under our [Fair
    # Usage Limits Policy]"); the explanatory prose says "maintains a", never
    # "under our". Grounding: all 9 PRs in the #1303 window that carried
    # fair_usage WITHOUT a rate_limit marker were re-read comment by comment;
    # every one still matches, and the #1292 prose comment no longer does.
    #
    # A reworded refusal falls through to `unclassified[]` rather than being
    # silently dropped — the designed-visible failure, not a silent undercount.
    {"tool": "coderabbit", "kind": "fair_usage",
     "pattern": "under our [fair usage limits policy]",
     "note": "the refusal clause, with CodeRabbit's usual markdown link. Both "
             "refusal verbs end in it — 'Your included review limit is "
             "currently reached under our [...]' and 'You're currently rate "
             "limited under our [...]' — and so do both banner generations in "
             "the #1303 window, the qualitative one ('...adaptive limits "
             "apply', 2026-07) and the quantitative one ('...based on your "
             "included PR review attempts over the past 7 days', 2026-08)"},
    {"tool": "coderabbit", "kind": "fair_usage",
     "pattern": "under our fair usage limits policy",
     "note": "same clause when CodeRabbit writes the policy name unlinked. "
             "Deduped per (PR, kind) with the pattern above, so a body "
             "carrying the linked form counts once, not twice"},
    {"tool": "codeant", "kind": "not_subscribed",
     "pattern": "add this email to the pr review subscription",
     "note": "CodeAnt seat/subscription gap; 24 occurrences in the sample"},
    {"tool": "codeant", "kind": "not_subscribed",
     "pattern": "no pr review subscription",
     "note": "shorter CodeAnt variant recorded in the 2026-06 audit"},
    {"tool": "codeant", "kind": "trial_exhausted",
     "pattern": "trial limit reached",
     "note": "CodeAnt free-trial exhaustion recorded in the 2026-06 audit"},
    {"tool": "bugbot", "kind": "spend_limit",
     "pattern": "hit a usage or spend limit",
     "note": "Cursor spend cap; 80 occurrences in the grounding sample"},
    {"tool": "bugbot", "kind": "spend_limit",
     "pattern": "increase usage limits in the",
     "note": "remediation line Cursor pairs with the cap message"},
    {"tool": "greptile", "kind": "quota",
     "pattern": "out of credits",
     "note": "Greptile per-review billing exhaustion"},
]

# A vendor states its own plan tier in some comment bodies. This is the only
# billed-state signal readable without a billing API.
PLAN_PATTERNS = [
    {"tool": "coderabbit", "regex": r"\*\*plan\*\*:\s*([A-Za-z][A-Za-z0-9 _-]{0,30})",
     "note": "CodeRabbit states its plan in the review-details block"},
]

# Generic probe for the unclassified report. Deliberately NOT a cap classifier:
# a hit here means "a human should look", never "this tool is capped".
LIMIT_SHAPED = re.compile(
    r"\b(usage limit|spend limit|rate limit|rate-limited|quota|out of credits|"
    r"subscription|upgrade your plan|billing|trial)\b", re.I)

# Vendor boilerplate lives in collapsible blocks and tip footers, and mentions
# limits routinely ("How do review limits work?"). Declared classifiers run on
# the raw body; the generic probe runs on the body with these stripped, so
# routine boilerplate does not drown the signal it is meant to surface.
BOILERPLATE = [
    re.compile(r"<details>.*?</details>", re.S | re.I),
    re.compile(r"<!--\s*tips_start\s*-->.*?<!--\s*tips_end\s*-->", re.S | re.I),
]


def strip_boilerplate(body):
    out = body
    for pat in BOILERPLATE:
        out = pat.sub(" ", out)
    return out


def load_gh_json(text):
    """Parse gh output that may be ONE JSON document or several concatenated.

    `gh api --paginate` documents its output as "Each page is a separate JSON
    array or object" — so a PR with more than 100 comments can yield `[...][...]`,
    which json.loads rejects outright. Some gh versions merge top-level arrays
    for REST list endpoints instead (2.93.0 does, for these endpoints), so the
    shape depends on the version and the endpoint. Accept both rather than
    depending on which one is installed: the failure this avoids is an audit
    that aborts on exactly the busy repos it is most useful for.

    Concatenated array pages are flattened into one list, matching what the
    single-document path returns.
    """
    text = (text or "").strip()
    if not text:
        return []
    try:
        return json.loads(text)
    except ValueError:
        pass
    decoder = json.JSONDecoder()
    merged, idx, length = [], 0, len(text)
    while idx < length:
        while idx < length and text[idx].isspace():
            idx += 1
        if idx >= length:
            break
        try:
            doc, end = decoder.raw_decode(text, idx)
        except ValueError:
            # Genuinely malformed, not merely multi-document. Signal to the
            # caller, which fails the run rather than measuring partial data.
            return None
        merged.extend(doc if isinstance(doc, list) else [doc])
        idx = end
    return merged


def run_gh(args):
    """Run gh, returning parsed JSON. Any failure is fatal: a snapshot built
    from partly-fetched data would understate every tool it failed to read."""
    try:
        proc = subprocess.run(["gh"] + args, capture_output=True, text=True)
    except OSError as exc:
        fail("could not execute gh: %s" % exc)
    if proc.returncode != 0:
        fail("gh %s failed (rc=%d): %s"
             % (" ".join(args[:2]), proc.returncode, proc.stderr.strip()[:400]))
    parsed = load_gh_json(proc.stdout)
    if parsed is None:
        fail("gh %s returned unparseable JSON" % " ".join(args[:2]))
    return parsed


# --- window -------------------------------------------------------------------
now = datetime.now(timezone.utc)
if since_arg:
    since = since_arg
    try:
        since_dt = datetime.strptime(since_arg, "%Y-%m-%d").replace(tzinfo=timezone.utc)
    except ValueError:
        fail("--since is not a valid date: %s" % since_arg)
    days = (now - since_dt).days
else:
    days = int(days_arg) if days_arg else 30
    since = (now - timedelta(days=days)).strftime("%Y-%m-%d")

notes = []

# --- gather -------------------------------------------------------------------
# `prs` is normalized to one shape regardless of source, so the classifier below
# runs identically on live data and on a fixture. That is what makes the tests
# exercise the real logic rather than a parallel implementation.
if fixture:
    source = "fixture"
    try:
        with open(fixture) as fh:
            bundle = json.load(fh)
    except (OSError, ValueError) as exc:
        fail("fixture unreadable: %s" % exc)
    if not isinstance(bundle, dict) or not isinstance(bundle.get("prs"), list):
        fail("fixture must be an object with a 'prs' array")
    repo = repo_arg or bundle.get("repo") or "(fixture)"
    prs = bundle["prs"]
else:
    source = "github"
    repo = repo_arg
    if not repo:
        info = run_gh(["repo", "view", "--json", "nameWithOwner"])
        repo = info.get("nameWithOwner") or ""
        if not repo:
            fail("could not infer the repo (pass --repo owner/name)")

    listed = run_gh([
        "pr", "list", "--repo", repo, "--state", "merged",
        "--search", "merged:>=%s" % since,
        "--limit", str(limit),
        "--json", "number,mergedAt",
    ])
    prs = []
    for row in listed:
        num = row.get("number")
        if num is None:
            continue
        reviews = run_gh(["api", "repos/%s/pulls/%d/reviews?per_page=100" % (repo, num), "--paginate"])
        pr_comments = run_gh(["api", "repos/%s/pulls/%d/comments?per_page=100" % (repo, num), "--paginate"])
        issue_comments = run_gh(["api", "repos/%s/issues/%d/comments?per_page=100" % (repo, num), "--paginate"])
        prs.append({
            "number": num,
            "merged_at": row.get("mergedAt"),
            "reviews": [{"user": (r.get("user") or {}).get("login", ""),
                         "state": r.get("state", ""),
                         "body": r.get("body") or ""} for r in reviews],
            "pr_comments": [{"user": (c.get("user") or {}).get("login", ""),
                             "body": c.get("body") or ""} for c in pr_comments],
            "issue_comments": [{"user": (c.get("user") or {}).get("login", ""),
                                "body": c.get("body") or ""} for c in issue_comments],
        })

truncated = (not fixture) and len(prs) >= limit
if truncated:
    notes.append(
        "Sample hit the --limit of %d, so the window may extend past what was "
        "measured. Throughput and findings counts are floors, not totals." % limit)

# --- classify -----------------------------------------------------------------
stats = {}
for t in TOOLS:
    stats[t["key"]] = {
        "key": t["key"], "login": t["login"], "name": t["name"],
        "prs_touched": 0, "review_objects": 0, "approved": 0,
        "changes_requested": 0, "inline_findings": 0, "issue_comments": 0,
        "sole_provider_on": 0, "plan_observed": None,
        "cap_signals": [], "cap_kinds": [],
        "_pr_ids": set(),
    }

unclassified = []
unclassified_seen = set()
# Entries are deduped per (tool, token) so one reworded vendor phrase repeated
# across 30 PRs does not produce 30 rows. But the DEDUPED count is what a human
# reads when deciding whether a new CAP_SIGNALS entry is warranted, and "1"
# reads as noise whether it happened once or thirty times. Keep the raw count
# so the report can state the frequency.
unclassified_hits = 0


def classify_body(key, pr_number, body):
    """Record cap signals and plan observations from one comment body."""
    if not body:
        return
    low = body.lower()
    matched = False
    for sig in CAP_SIGNALS:
        if sig["tool"] != key:
            continue
        if sig["pattern"] in low:
            matched = True
            entry = {"pr": pr_number, "kind": sig["kind"], "pattern": sig["pattern"]}
            # Dedupe per (PR, kind): one capped PR is one observation however
            # many comments the vendor posts about it.
            dup = any(c["pr"] == pr_number and c["kind"] == sig["kind"]
                      for c in stats[key]["cap_signals"])
            if not dup:
                stats[key]["cap_signals"].append(entry)
    for pp in PLAN_PATTERNS:
        if pp["tool"] != key:
            continue
        # Case-insensitive: CodeRabbit writes "> **Plan**: Pro", not lowercase.
        m = re.search(pp["regex"], body, re.I)
        if m and not stats[key]["plan_observed"]:
            stats[key]["plan_observed"] = m.group(1).strip().lower()
    if not matched:
        probe = strip_boilerplate(body)
        hit = LIMIT_SHAPED.search(probe)
        if hit:
            global unclassified_hits
            unclassified_hits += 1
            token = hit.group(0).lower()
            dedupe_key = (key, token)
            if dedupe_key not in unclassified_seen:
                unclassified_seen.add(dedupe_key)
                start = max(0, hit.start() - 60)
                unclassified.append({
                    "tool": key, "pr": pr_number, "token": token,
                    "excerpt": " ".join(probe[start:hit.end() + 60].split()),
                })


for pr in prs:
    num = pr.get("number")
    finders_on_pr = set()

    for rv in pr.get("reviews", []):
        key = LOGIN_TO_KEY.get(rv.get("user", ""))
        if not key:
            continue
        s = stats[key]
        s["review_objects"] += 1
        s["_pr_ids"].add(num)
        state = (rv.get("state") or "").upper()
        if state == "APPROVED":
            s["approved"] += 1
        elif state == "CHANGES_REQUESTED":
            s["changes_requested"] += 1
        classify_body(key, num, rv.get("body") or "")

    for c in pr.get("pr_comments", []):
        key = LOGIN_TO_KEY.get(c.get("user", ""))
        if not key:
            continue
        s = stats[key]
        # Inline diff comments are the cleanest available proxy for "a finding",
        # matching the methodology of the 2026-04 and 2026-06 hand audits.
        s["inline_findings"] += 1
        s["_pr_ids"].add(num)
        finders_on_pr.add(key)
        classify_body(key, num, c.get("body") or "")

    for c in pr.get("issue_comments", []):
        key = LOGIN_TO_KEY.get(c.get("user", ""))
        if not key:
            continue
        s = stats[key]
        s["issue_comments"] += 1
        s["_pr_ids"].add(num)
        classify_body(key, num, c.get("body") or "")

    # Sole-provider: the unique-value signal. Only meaningful when exactly one
    # tool posted an inline finding on this PR.
    if len(finders_on_pr) == 1:
        stats[next(iter(finders_on_pr))]["sole_provider_on"] += 1

tools_out = []
for t in TOOLS:
    s = stats[t["key"]]
    s["prs_touched"] = len(s["_pr_ids"])
    del s["_pr_ids"]
    s["cap_kinds"] = sorted({c["kind"] for c in s["cap_signals"]})
    if s["prs_touched"] == 0:
        s["observed_state"] = "silent"
    elif s["cap_signals"]:
        # `capped` wins over `active`: a tool that reviewed AND hit a limit is
        # the case the audit most needs to see. Its throughput numbers still
        # show what it managed before the cap.
        s["observed_state"] = "capped"
    else:
        s["observed_state"] = "active"
    tools_out.append(s)

if unclassified:
    notes.append(
        "%d distinct (tool, token) pair(s) across %d limit-shaped comment(s) "
        "matched no declared classifier — see `unclassified`. These are NOT "
        "counted as caps; a human decides whether the CAP_SIGNALS table needs a "
        "new phrase. The comment count is the one to weigh: a phrase recurring "
        "across many PRs is a vendor reword, not noise."
        % (len(unclassified), unclassified_hits))

snapshot = {
    "generated_at": now.strftime("%Y-%m-%dT%H:%M:%SZ"),
    "repo": repo,
    "source": source,
    "window": {
        "since": since,
        "until": now.strftime("%Y-%m-%d"),
        "days": days,
        "pr_count": len(prs),
        "limit": limit,
        "truncated": truncated,
    },
    "tools": tools_out,
    "unclassified": unclassified,
    "unclassified_hits": unclassified_hits,
    "notes": notes,
}

if mode == "summary":
    for s in tools_out:
        print("%s\t%s\t%d\t%d\t%d" % (s["key"], s["observed_state"],
                                      s["prs_touched"], s["inline_findings"],
                                      s["sole_provider_on"]))
else:
    print(json.dumps(snapshot, indent=2, sort_keys=True))
PY
