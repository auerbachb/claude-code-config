#!/usr/bin/env bash
# Find existing issues that may already cover a finding — TITLE *and* BODY.
#
# Usage: issue-dedup.sh <keywords> [options]
#        issue-dedup.sh --help
#
# Shared recall layer for automated issue filing (/wrap Phase 3, /issue-maker
# Step 4). It fetches the repo's open issues plus recently-closed ones, scores
# each against the finding's keywords over BOTH title and body, and prints the
# ranked candidates as JSON. It deliberately does NOT decide whether a candidate
# is a duplicate — that judgment (strong / weak / none) belongs to the caller and
# is specified in .claude/reference/autofile-dedup.md.
#
# Body coverage is the point: issue #647 duplicated #638 while sharing almost no
# title words, so a title-only search (the pre-#652 behavior of both callers)
# could not have caught it.
#
# Options:
#   --repo <owner/name>    Target repo (default: gh's current-repo inference)
#   --open-limit N         Open issues to scan (default 150)
#   --closed-days N        Also scan issues closed within N days (default 30;
#                          0 disables the closed-issue scan)
#   --closed-limit N       Closed issues to scan (default 100)
#   --min-coverage F       Drop candidates below this keyword coverage, 0..1
#                          (default 0.34 — roughly "at least a third of the
#                          finding's distinct terms appear somewhere")
#   --max-results N        Cap emitted candidates (default 5)
#   --exclude N[,N...]     Issue numbers to omit (e.g. issues this run just filed)
#
# Output (stdout): JSON array, highest score first. Each element:
#   {number, title, url, state, score, coverage, title_hits, body_hits,
#    terms_matched, terms_missed}
#   - coverage    fraction of the finding's distinct terms found anywhere
#   - title_hits  terms found in the candidate's title
#   - body_hits   terms found in the candidate's body
#   - score       coverage plus a small title-agreement bonus, capped at 1.0;
#                 a ranking aid only — never a decision threshold on its own
#
# Exit codes:
#   0  At least one candidate at/above --min-coverage (JSON array on stdout)
#   1  No candidate (prints `[]`) — including the no-usable-keywords case
#   2  Usage error
#   4  gh / network / environment error (gh or python3 missing or failing, or
#      unparseable gh output)
#
# Callers: .claude/skills/wrap/SKILL.md (Steps 3.3 / 3.7),
#          .claude/skills/issue-maker/SKILL.md (Step 4).
# Thresholds and the comment-vs-file decision: .claude/reference/autofile-dedup.md

set -euo pipefail
printf '%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$(basename "$0")" "${*//$'\n'/ }" >> "$HOME/.claude/script-usage.log" 2>/dev/null || true

usage() {
  sed -n '3,47p' "$0" | sed 's/^# \{0,1\}//'
}

if [ "$#" -eq 0 ]; then
  usage >&2
  exit 2
fi

case "$1" in
  -h|--help) usage; exit 0 ;;
esac

KEYWORDS="$1"
shift

REPO=""
OPEN_LIMIT=150
CLOSED_DAYS=30
CLOSED_LIMIT=100
MIN_COVERAGE=0.34
MAX_RESULTS=5
EXCLUDE=""

# Every option below takes a value. Without this guard a trailing bare flag
# (`--repo` with nothing after it) makes `shift 2` fail under `set -e`, which
# exits 1 — indistinguishable from "searched, found nothing" to a caller that
# reads exit codes. Usage errors must always be 2.
need_value() {
  # need_value <flag> <remaining-arg-count>
  if [ "$2" -lt 2 ]; then
    echo "issue-dedup.sh: option '$1' requires a value" >&2
    exit 2
  fi
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo)         need_value "$1" "$#"; REPO="$2"; shift 2 ;;
    --open-limit)   need_value "$1" "$#"; OPEN_LIMIT="$2"; shift 2 ;;
    --closed-days)  need_value "$1" "$#"; CLOSED_DAYS="$2"; shift 2 ;;
    --closed-limit) need_value "$1" "$#"; CLOSED_LIMIT="$2"; shift 2 ;;
    --min-coverage) need_value "$1" "$#"; MIN_COVERAGE="$2"; shift 2 ;;
    --max-results)  need_value "$1" "$#"; MAX_RESULTS="$2"; shift 2 ;;
    --exclude)      need_value "$1" "$#"; EXCLUDE="$2"; shift 2 ;;
    -h|--help)      usage; exit 0 ;;
    *) echo "issue-dedup.sh: unknown option '$1'" >&2; usage >&2; exit 2 ;;
  esac
done

for n in "$OPEN_LIMIT" "$CLOSED_DAYS" "$CLOSED_LIMIT" "$MAX_RESULTS"; do
  case "$n" in
    ''|*[!0-9]*) echo "issue-dedup.sh: limits and --closed-days must be non-negative integers" >&2; exit 2 ;;
  esac
done
case "$MIN_COVERAGE" in
  ''|.|*[!0-9.]*|*.*.*) echo "issue-dedup.sh: --min-coverage must be a number between 0 and 1" >&2; exit 2 ;;
esac
# Range check too: coverage is a fraction, so 1.5 is a caller mistake, not a
# very strict filter. awk rather than python3 — no extra process dependency
# before the environment checks below.
if ! awk -v v="$MIN_COVERAGE" 'BEGIN { exit !(v >= 0 && v <= 1) }'; then
  echo "issue-dedup.sh: --min-coverage must be a number between 0 and 1" >&2
  exit 2
fi

command -v python3 >/dev/null 2>&1 || { echo "issue-dedup.sh: python3 not found" >&2; exit 4; }
command -v gh >/dev/null 2>&1 || { echo "issue-dedup.sh: gh not found" >&2; exit 4; }

# Note the `${arr[@]+…}` guard at each use site: bash 3.2 (macOS system bash)
# treats an empty array expansion as unbound under `set -u`.
REPO_ARGS=()
if [ -n "$REPO" ]; then REPO_ARGS=(--repo "$REPO"); fi

FIELDS="number,title,body,url,state"

# A plain listing (no --search) is intentional: search relevance is opaque and
# title-weighted, whereas scoring locally lets us weigh body text the same way
# and stay deterministic under test.
#
# stderr is captured separately, never folded into stdout: gh prints warnings
# (deprecations, auth notices) on stderr while still succeeding, and `2>&1` here
# would splice those lines into the JSON and fail the parse.
STDERR_FILE=$(mktemp)
trap 'rm -f "$STDERR_FILE"' EXIT

fetch_issues() {
  # fetch_issues <state> <limit> [extra gh args...]
  local state="$1" limit="$2"
  shift 2
  gh issue list "${REPO_ARGS[@]+"${REPO_ARGS[@]}"}" --state "$state" --limit "$limit" \
    --json "$FIELDS" "$@" 2>"$STDERR_FILE"
}

if ! OPEN_JSON=$(fetch_issues open "$OPEN_LIMIT"); then
  echo "issue-dedup.sh: gh issue list (open) failed: $(cat "$STDERR_FILE")" >&2
  # Valid JSON on every exit path, so a caller can parse unconditionally — but
  # exit 4, never 1: a failed search is not "no duplicates found".
  echo "[]"
  exit 4
fi

CLOSED_JSON='[]'
if [ "$CLOSED_DAYS" -gt 0 ]; then
  CLOSED_SINCE=$(date -u -d "${CLOSED_DAYS} days ago" +%F 2>/dev/null || date -u -v-"${CLOSED_DAYS}"d +%F)
  if ! CLOSED_JSON=$(fetch_issues closed "$CLOSED_LIMIT" --search "closed:>${CLOSED_SINCE}"); then
    # A failed closed-issue scan degrades to open-only rather than failing the
    # caller: fewer candidates biases toward filing, which is the safe direction.
    echo "issue-dedup.sh: gh issue list (closed) failed, continuing with open issues only: $(cat "$STDERR_FILE")" >&2
    CLOSED_JSON='[]'
  fi
fi

RESULT=$(
  KEYWORDS="$KEYWORDS" MIN_COVERAGE="$MIN_COVERAGE" MAX_RESULTS="$MAX_RESULTS" \
  EXCLUDE="$EXCLUDE" OPEN_JSON="$OPEN_JSON" CLOSED_JSON="$CLOSED_JSON" \
  python3 <<'PY'
import json, os, re, sys

# Generic words carry no discriminating signal in an engineering tracker: they
# appear in most issue bodies, so leaving them in inflates coverage toward a
# false "strong match" — the failure mode this whole helper exists to avoid.
STOPWORDS = {
    "the","and","for","with","that","this","from","into","when","then","than","have",
    "has","are","was","were","will","would","should","could","not","but","its","it's",
    "you","your","our","their","all","any","use","used","uses","using","via",
    "per","out","off","get","got","set","sets","new","old","one","two","now","also",
    "only","just","still","every","each","some","more","most","less","same","other",
    "issue","issues","ticket","tickets","bug","bugs","fix","fixes","fixed","file",
    "files","script","scripts","code","change","changes","changed","add","adds",
    "added","make","makes","made","run","runs","running","work","works","need",
    "needs","because","after","before","while","between","across","under","over",
    "does","doesn't","don't","can","cannot","may","might","must","repo","pull",
    "request","claude","agent","agents",
}

def tokenize(text):
    """Split into comparable terms, keeping identifier punctuation (_ - . /)."""
    raw = re.findall(r"[A-Za-z0-9][A-Za-z0-9_./-]*", text.lower())
    terms = []
    for t in raw:
        t = t.strip("./-")
        if len(t) < 3 or t in STOPWORDS or t.isdigit():
            continue
        if t not in terms:
            terms.append(t)
    return terms

terms = tokenize(os.environ["KEYWORDS"])[:12]
if not terms:
    print("[]")
    sys.exit(1)

def hits(term, haystack):
    """Boundary-aware containment. Letters, digits and `_` bind (so `poll` does
    not match `polling`); `.` and `-` separate, so `root_repo` matches inside
    `.prs[<N>].root_repo` — which is exactly the #638/#647 overlap."""
    return re.search(r"(?<![A-Za-z0-9_])" + re.escape(term) + r"(?![A-Za-z0-9_])", haystack) is not None

exclude = {n.strip() for n in os.environ.get("EXCLUDE", "").split(",") if n.strip()}
min_cov = float(os.environ["MIN_COVERAGE"])
max_results = int(os.environ["MAX_RESULTS"])

def load(name):
    try:
        data = json.loads(os.environ[name] or "[]")
    except json.JSONDecodeError:
        print("issue-dedup.sh: could not parse gh JSON output", file=sys.stderr)
        sys.exit(4)
    return data if isinstance(data, list) else []

def score_all():
    candidates = []
    seen = set()
    for issue in load("OPEN_JSON") + load("CLOSED_JSON"):
        number = issue.get("number")
        if number is None or str(number) in exclude or number in seen:
            continue
        seen.add(number)
        title = (issue.get("title") or "").lower()
        body = (issue.get("body") or "").lower()
        matched, missed, title_hits, body_hits = [], [], 0, 0
        for term in terms:
            in_title, in_body = hits(term, title), hits(term, body)
            if in_title:
                title_hits += 1
            if in_body:
                body_hits += 1
            (matched if (in_title or in_body) else missed).append(term)
        coverage = len(matched) / len(terms)
        if coverage < min_cov:
            continue
        # Title agreement is weak corroboration, not a gate — #638/#647 shared
        # almost no title words yet were the same problem.
        score = min(1.0, coverage + 0.1 * (title_hits > 0))
        candidates.append({
            "number": number,
            "title": issue.get("title") or "",
            "url": issue.get("url") or "",
            "state": (issue.get("state") or "").upper(),
            "score": round(score, 3),
            "coverage": round(coverage, 3),
            "title_hits": title_hits,
            "body_hits": body_hits,
            "terms_matched": matched,
            "terms_missed": missed,
        })
    # Open issues outrank closed ones at equal score: only an open issue can
    # absorb a finding as a comment.
    candidates.sort(key=lambda c: (c["state"] == "OPEN", c["score"], c["title_hits"], -c["number"]), reverse=True)
    return candidates[:max_results]

# An unexpected exception must not exit 1: exit 1 is the documented "searched,
# found nothing" result, and a caller that reads a crash as "no duplicates"
# silently loses the check it thinks it ran.
try:
    candidates = score_all()
except SystemExit:
    raise
except Exception as exc:  # noqa: BLE001 — deliberate catch-all, re-raised as exit 4
    print("issue-dedup.sh: unexpected scoring error: %s" % exc, file=sys.stderr)
    print("[]")
    sys.exit(4)

print(json.dumps(candidates, indent=2))
sys.exit(0 if candidates else 1)
PY
) || PY_STATUS=$?

# Always emit valid JSON so a caller can parse unconditionally, whatever the exit.
printf '%s\n' "${RESULT:-[]}"
exit "${PY_STATUS:-0}"
