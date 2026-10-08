#!/usr/bin/env bash
# review-daily-cap.sh — Account-level daily soft cap on paid AI reviewer triggers.
# catalog: review-escalation — Tally today's (ET) spend for one paid reviewer across every registered repo and say whether one more trigger stays under the account's daily cap
#
# PURPOSE
#   The review vendors cap the whole account, not a repo: CodeRabbit's usage
#   pool is org-wide, Cursor's spend limit covers every repo, and Greptile's
#   flex cap is per org. Two repos that each honour their own $10 can draw $20
#   from an account with one cap, and neither can see the other (issue #1812,
#   increment 5/5 of #1747). This helper is the one account-level answer every
#   paid trigger asks before it spends: today's spend for one platform, summed
#   across every repo review-repos.sh registers, against one cap from the
#   account config.
#
#   The cap is SOFT. It fails open with a visible `unknown` whenever the tally
#   cannot be read, and the vendors' own caps stay the hard stop. Spend comes
#   from live GitHub evidence priced by lib/review_ledger.py, so it also counts
#   spend the harness did not trigger (vendor auto-reviews, CI nudges). Receipts
#   and estimates are a floor, so the cap errs toward spending slightly more
#   than it thinks, never less. Policy: .claude/reference/review-policy.md
#   "Account-level daily cap".
#
# USAGE
#   review-daily-cap.sh <platform> [--add-usd X] [--fixture <path>]
#   review-daily-cap.sh <platform> --rate [--fixture <path>]
#   review-daily-cap.sh --help | -h
#
#   <platform>        bugbot | coderabbit | greptile
#   --add-usd X       The trigger about to be posted, in USD (default 0). The
#                     status is `over` when spent + X is strictly above the cap.
#   --rate            Print the platform's per-review USD figure (one number)
#                     for a caller to pass as --add-usd, and exit 0. See RATE.
#   --fixture <path>  Read the day's events from a file instead of GitHub. No
#                     review-repos.sh, no gh, no cache. See FIXTURE FORMAT.
#
# CAP
#   Per platform, first match wins:
#     1. env REVIEW_DAILY_CAP_USD_<PLATFORM> (BUGBOT, CODERABBIT, GREPTILE);
#        set but blank counts as unset.
#     2. The `## Review daily caps` section of the account config, read with
#        `pm-config-get.sh --file "${CLAUDE_ACCOUNT_CONFIG:-$HOME/.claude/account-config.md}"`.
#        Lines are `KEY = value` or `KEY: value`, the key matched in any case,
#        the first occurrence wins, a trailing `# note` is dropped, and HTML
#        comments are ignored.
#     3. The default, 10.
#   A value must be a non-negative decimal (`10`, `7.50`, `0`). Anything else —
#   `$10`, `ten`, `-1` — warns on stderr and uses the default. A missing config
#   file or section uses the default silently; a config that exists but cannot
#   be read warns and uses the default.
#
# TALLY
#   The current America/New_York calendar day decides, never the UTC date: an
#   event at 02:00Z on the 9th is the 8th's spend in ET. Live mode lists every
#   repo from review-repos.sh, reads the PRs updated since ET midnight (one
#   GraphQL query per page of 10 PRs, newest first), and prices that day's
#   events with lib/review_ledger.py — the /review-stack-audit ledger's own
#   extraction and money rules:
#     bugbot      `Cursor Bugbot` check-runs from the `cursor` app, by
#                 started_at, deduplicated by run id, x the per-review rate.
#     coderabbit  `Charged: $X` receipts in coderabbitai[bot] comments, timed
#                 by the comment's last edit. A floor.
#     greptile    non-bot `@greptileai` comments x credits/review x $/credit.
#   Rates come from the `review-stack-rates` block in
#   .claude/reference/pricing-matrix.md. A null rate makes the tally `unknown`.
#   A PR with more than 50 commits or 100 comments, or a repo with more than
#   100 PRs updated today, is read in part and noted on stderr: the figure is
#   then a floor, like every receipt.
#
# CACHE
#   A known live tally is cached per platform and ET day in
#   ~/.claude/review-daily-cap/<platform>-<YYYY-MM-DD>.json for 5 minutes. Only
#   spent_usd is cached: the cap and --add-usd are applied on every call, so a
#   cap edit takes effect at once. An `unknown` tally is never cached, and a
#   cache read or write failure only costs a fresh read. Fixtures never touch it.
#
# RATE (--rate)
#   bugbot: the block's per-review rate. coderabbit: none (receipt-priced).
#   greptile: $/credit x credits/review. When that reads null, the env override
#   REVIEW_RATE_USD_<PLATFORM> is used, then a documented fallback — BugBot
#   only, 1.58, the measured $815.58 / 516 reviews average the block itself
#   cites (pricing-matrix.md, #1204). With none of those, 0 is printed and a
#   note says why: `--add-usd 0` then asks only whether the account is already
#   over.
#
# FIXTURE FORMAT
#   measure.sh's normalized multi-repo shape, which is what the ledger's
#   extraction functions read:
#     {"repos": [{"repo": "owner/name",
#                 "prs": [{"number": 1,
#                          "check_runs": [{"id": 9, "name": "Cursor Bugbot",
#                                          "app": "cursor", "started_at": "..."}],
#                          "issue_comments": [{"user": "coderabbitai[bot]", "body": "...",
#                                              "created_at": "...", "updated_at": "..."}]}]}],
#      "rates": {...}}
#   `rates` is optional: a review-stack-rates/v1 document (the JSON the fenced
#   block holds), validated exactly as the block is. Without it, the pricing
#   file is read. An empty `repos` array is an `unknown` tally, as an empty
#   registry is live.
#
# OUTPUT
#   One JSON line on stdout:
#     {"platform":"bugbot","date":"2026-10-08","spent_usd":4.74,"add_usd":1.58,
#      "cap_usd":5.0,"status":"over"}
#   status is `ok`, `over`, or `unknown`. spent_usd is null exactly when the
#   status is `unknown` — an unreadable tally is never reported as 0. Why a
#   tally is unknown, and every partial-read note, goes to stderr.
#
# EXIT STATUS
#   0   ok, or unknown (fail open: the caller posts); also --rate
#   1   over (the caller skips the trigger)
#   2   usage error: unknown platform or flag, malformed --add-usd, missing or
#       malformed fixture
#   70  --help header extraction produced no output (internal defect)
#
# ENVIRONMENT
#   REVIEW_DAILY_CAP_USD_<PLATFORM>  cap override (see CAP)
#   CLAUDE_ACCOUNT_CONFIG            account config path
#   REVIEW_RATE_USD_<PLATFORM>       rate fallback when the block's rate is null
#   REVIEW_DAILY_CAP_NOW             the clock, as epoch seconds or ISO-8601
#                                    (tests); default: now
#
# DEPENDENCIES
#   python3 (stdlib only) and lib/review_ledger.py; gh for the live tally;
#   review-repos.sh; pm-config-get.sh for the config. Any of them missing makes
#   the answer `unknown` (or the default cap), with a stderr line naming it.
#
# EXAMPLES
#   review-daily-cap.sh bugbot --add-usd "$(review-daily-cap.sh bugbot --rate)"
#   REVIEW_DAILY_CAP_USD_BUGBOT=5 review-daily-cap.sh bugbot --add-usd 1.58 --fixture day.json

set -uo pipefail
printf '%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$(basename "$0")" "${*//$'\n'/ }" 2>/dev/null >> "$HOME/.claude/script-usage.log" || true

print_help() {
  awk 'NR == 1 { next } /^# catalog:/ { next } /^#/ { sub(/^# ?/, ""); print; n = 1; next } { exit } END { exit(n ? 0 : 1) }' "$0" ||
    { printf '%s: --help header extraction produced no output\n' "$0" >&2; exit 70; }
}

usage_error() {
  echo "review-daily-cap.sh: $1" >&2
  echo "Run with --help for usage." >&2
  exit 2
}

DEFAULT_CAP_USD=10
# The one definition of the BugBot fallback rate (see RATE in the header).
FALLBACK_RATE_USD_BUGBOT=1.58
NUM_RE='^(0|[1-9][0-9]*)(\.[0-9]+)?$'

PLATFORM=""
ADD_USD=""
FIXTURE=""
MODE="check"
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) print_help; exit 0 ;;
    --add-usd)
      [[ $# -ge 2 ]] || usage_error "--add-usd requires a value"
      ADD_USD="$2"; shift 2 ;;
    --add-usd=*) ADD_USD="${1#--add-usd=}"; shift ;;
    --fixture)
      [[ $# -ge 2 && -n "$2" ]] || usage_error "--fixture requires a value"
      FIXTURE="$2"; shift 2 ;;
    --fixture=*)
      FIXTURE="${1#--fixture=}"; [[ -n "$FIXTURE" ]] || usage_error "--fixture value cannot be empty"; shift ;;
    --rate) MODE="rate"; shift ;;
    --) shift; break ;;
    -*) usage_error "unknown flag: $1" ;;
    *)
      [[ -z "$PLATFORM" ]] || usage_error "unexpected argument: $1"
      PLATFORM="$1"; shift ;;
  esac
done
[[ $# -eq 0 ]] || usage_error "unexpected argument: $1"

case "$PLATFORM" in
  bugbot|coderabbit|greptile) ;;
  "") usage_error "a platform is required (bugbot, coderabbit, greptile)" ;;
  *) usage_error "unknown platform '$PLATFORM' (expected bugbot, coderabbit, or greptile)" ;;
esac
if [[ "$MODE" == "rate" && -n "$ADD_USD" ]]; then
  usage_error "--rate and --add-usd cannot be combined"
fi
ADD_USD="${ADD_USD:-0}"
[[ "$ADD_USD" =~ $NUM_RE ]] || usage_error "--add-usd must be a non-negative decimal, got '$ADD_USD'"
if [[ -n "$FIXTURE" ]]; then
  [[ -f "$FIXTURE" && -r "$FIXTURE" ]] || usage_error "fixture not readable: $FIXTURE"
fi

UPPER="$(printf '%s' "$PLATFORM" | tr '[:lower:]' '[:upper:]')"
SELF_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || SELF_DIR=""

# resolve <relative path under .claude/> — this checkout first (version-
# consistent with this script), then the published locations
# (portable-skill-resolution.md). Prints the first readable match.
resolve() {
  local rel="$1" c
  for c in \
    ${SELF_DIR:+"$SELF_DIR/../$rel"} \
    ${HOME:+"$HOME/.claude/skills-worktree/.claude/$rel"} \
    ${HOME:+"$HOME/.claude/$rel"} \
    ".claude/$rel"; do
    if [[ -r "$c" && -f "$c" ]]; then printf '%s\n' "$c"; return 0; fi
  done
  return 1
}

# --- the rate fallback (env, then the documented constant) --------------------
fallback_rate() {
  local env_rate
  env_rate="$(printenv "REVIEW_RATE_USD_$UPPER" 2>/dev/null)" || env_rate=""
  if [[ -n "$env_rate" ]]; then
    if [[ "$env_rate" =~ $NUM_RE ]]; then printf '%s' "$env_rate"; return 0; fi
    echo "review-daily-cap.sh: REVIEW_RATE_USD_$UPPER='$env_rate' is not a non-negative decimal; ignoring it" >&2
  fi
  if [[ "$PLATFORM" == "bugbot" ]]; then printf '%s' "$FALLBACK_RATE_USD_BUGBOT"; return 0; fi
  return 1
}

# --- the cap ------------------------------------------------------------------
cap_from_config() {
  local config="${CLAUDE_ACCOUNT_CONFIG:-${HOME:-}/.claude/account-config.md}"
  local key="REVIEW_DAILY_CAP_USD_$UPPER" getter section rc
  [[ -e "$config" || -L "$config" ]] || return 1
  if [[ ! -f "$config" || ! -r "$config" ]]; then
    echo "review-daily-cap.sh: account config is not a readable file: $config — using the default cap" >&2
    return 1
  fi
  getter="$(resolve scripts/pm-config-get.sh)" && [[ -x "$getter" ]] || {
    echo "DEGRADED: pm-config-get.sh not found (checked all three paths) — account cap config unavailable, continuing with the default cap" >&2
    return 1
  }
  section="$("$getter" --file "$config" --section "Review daily caps" 2>/dev/null)"
  rc=$?
  case "$rc" in
    0) ;;
    1) return 1 ;;   # no such section, or empty: the default, silently
    *) echo "review-daily-cap.sh: pm-config-get.sh failed reading $config (rc=$rc) — using the default cap" >&2
       return 1 ;;
  esac
  # HTML comments are notes, never settings (the same stripping review-repos.sh
  # applies to the same file), then the first `KEY = value` / `KEY: value`.
  printf '%s\n' "$section" | awk -v want="$(printf '%s' "$key" | tr '[:upper:]' '[:lower:]')" '
    {
      line = $0; out = ""
      while (1) {
        if (comment) {
          i = index(line, "-->")
          if (i == 0) { line = ""; break }
          line = substr(line, i + 3); comment = 0
        } else {
          i = index(line, "<!--")
          if (i == 0) { out = out line; break }
          out = out substr(line, 1, i - 1); line = substr(line, i + 4); comment = 1
        }
      }
      k = out
      sub(/^[[:space:]]*/, "", k)
      if (!match(k, /^[A-Za-z0-9_]+[[:space:]]*[=:]/)) next
      name = substr(k, 1, RLENGTH)
      sub(/[[:space:]]*[=:]$/, "", name)
      if (tolower(name) != want) next
      v = substr(k, RLENGTH + 1)
      sub(/[[:space:]]+#.*$/, "", v)
      sub(/^[[:space:]]+/, "", v)
      sub(/[[:space:]]+$/, "", v)
      print v
      found = 1
      exit
    }
    END { exit(found ? 0 : 1) }
  '
}

resolve_cap() {
  local key="REVIEW_DAILY_CAP_USD_$UPPER" val
  val="$(printenv "$key" 2>/dev/null)" || val=""
  if [[ -n "$val" ]]; then
    if [[ "$val" =~ $NUM_RE ]]; then printf '%s' "$val"; return; fi
    echo "review-daily-cap.sh: $key='$val' (env) is not a non-negative decimal; using the default cap $DEFAULT_CAP_USD" >&2
    printf '%s' "$DEFAULT_CAP_USD"; return
  fi
  if val="$(cap_from_config)"; then
    if [[ "$val" =~ $NUM_RE ]]; then printf '%s' "$val"; return; fi
    echo "review-daily-cap.sh: $key='$val' (account config) is not a non-negative decimal; using the default cap $DEFAULT_CAP_USD" >&2
  fi
  printf '%s' "$DEFAULT_CAP_USD"
}

# --- fail-open fallbacks for a run Python cannot finish ---------------------------
et_today() { TZ='America/New_York' date +'%Y-%m-%d'; }

# A validated decimal in the same shortest form Python prints (10.00 -> 10,
# 7.50 -> 7.5), without needing Python.
canon_num() {
  local v="$1"
  if [[ "$v" == *.* ]]; then
    while [[ "$v" == *0 ]]; do v="${v%0}"; done
    v="${v%.}"
  fi
  printf '%s' "$v"
}

emit_unknown() {   # <reason>
  echo "review-daily-cap.sh: unknown — $1 (fails open: the trigger may post)" >&2
  printf '{"platform":"%s","date":"%s","spent_usd":null,"add_usd":%s,"cap_usd":%s,"status":"unknown"}\n' \
    "$PLATFORM" "$(et_today)" "$(canon_num "$ADD_USD")" "$(canon_num "$CAP_USD")"
  exit 0
}

emit_fallback_rate() {   # <reason>
  local rate
  if rate="$(fallback_rate)"; then
    echo "review-daily-cap.sh: $1 — using the fallback $PLATFORM rate $rate" >&2
    printf '%s\n' "$rate"
  else
    echo "review-daily-cap.sh: $1, and $PLATFORM has no fallback rate — printing 0" >&2
    printf '0\n'
  fi
  exit 0
}

CAP_USD=""
[[ "$MODE" == "rate" ]] || CAP_USD="$(resolve_cap)"

LIB_PY=""
LIB_PY="$(resolve scripts/lib/review_ledger.py)" || LIB_PY=""
if ! command -v python3 >/dev/null 2>&1; then
  [[ "$MODE" == "rate" ]] && emit_fallback_rate "python3 not found"
  emit_unknown "python3 not found"
fi
if [[ -z "$LIB_PY" ]]; then
  echo "ERROR: review_ledger.py not found (checked all three paths) — the spend tally is unavailable" >&2
  [[ "$MODE" == "rate" ]] && emit_fallback_rate "review_ledger.py not found"
  emit_unknown "review_ledger.py not found"
fi
# CodeRabbit's tally reads receipts, never a rate, so only the other platforms
# (and every --rate lookup) lose anything when the pricing file is missing. A
# fixture may carry its own rates; Python names the gap if it does not.
PRICING=""
if ! PRICING="$(resolve reference/pricing-matrix.md)"; then
  PRICING=""
  if [[ -z "$FIXTURE" && ( "$PLATFORM" != "coderabbit" || "$MODE" == "rate" ) ]]; then
    echo "DEGRADED: pricing-matrix.md not found (checked all three paths) — the $PLATFORM rate is unavailable, continuing without it" >&2
  fi
fi
REVIEW_REPOS_SH=""
if [[ -z "$FIXTURE" && "$MODE" == "check" ]]; then
  REVIEW_REPOS_SH="$(resolve scripts/review-repos.sh)" && [[ -x "$REVIEW_REPOS_SH" ]] || REVIEW_REPOS_SH=""
fi
FALLBACK_RATE=""
FALLBACK_RATE="$(fallback_rate 2>/dev/null)" || FALLBACK_RATE=""

# The program is read into a variable here, OUTSIDE any $( ): bash 3.2 scans a
# heredoc nested in a command substitution for parentheses and quotes, so one
# stray character in the Python would misparse the whole script.
PY_SRC=""
IFS= read -r -d '' PY_SRC <<'PY' || true
import json
import os
import subprocess
import sys
import tempfile
import time
from datetime import date, datetime, timedelta, timezone
from decimal import Decimal

PLATFORM = os.environ["RDC_PLATFORM"]
MODE = os.environ["RDC_MODE"]
TTL_SECONDS = 300
GH_TIMEOUT = 90
PR_PAGE = 10        # PRs per GraphQL page
MAX_PAGES = 10      # 100 PRs per repo per ET day before the read is partial
COMMITS_READ = 50
COMMENTS_READ = 100
EXIT_USAGE = 2


def note(msg):
    print("review-daily-cap.sh: %s" % msg, file=sys.stderr)


class Unknown(Exception):
    """The tally cannot be read; the answer is `unknown`, never 0."""


sys.path.insert(0, os.environ["RDC_LIB_DIR"])
try:
    import review_ledger as ledger
except Exception as exc:   # any import-time fault is an unreadable tally
    note("could not import review_ledger.py: %s" % exc)
    sys.exit(3)

ADD = ledger.cents(Decimal(os.environ["RDC_ADD_USD"]))


# --- the clock and the ET day -------------------------------------------------
def now_epoch():
    raw = os.environ.get("REVIEW_DAILY_CAP_NOW", "").strip()
    if not raw:
        return time.time()
    if raw.isdigit():
        return float(raw)
    text = raw[:-1] + "+00:00" if raw.endswith(("Z", "z")) else raw
    try:
        dt = datetime.fromisoformat(text)
    except ValueError:
        note("REVIEW_DAILY_CAP_NOW='%s' is neither epoch seconds nor ISO-8601" % raw)
        sys.exit(EXIT_USAGE)
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt.timestamp()


def et_day(epoch):
    """(YYYY-MM-DD, start, end) of the America/New_York day holding `epoch`;
    start and end are aware UTC datetimes, end exclusive. Reads the system
    zone database through libc, as `TZ=America/New_York date` does. A missing
    zone would silently read as UTC, so that case is refused, never guessed."""
    os.environ["TZ"] = "America/New_York"
    time.tzset()
    if set(time.tzname) != {"EST", "EDT"}:
        raise Unknown("the America/New_York zone is not available here (TZ read as %s)"
                      % "/".join(time.tzname))
    lt = time.localtime(epoch)
    day = date(lt.tm_year, lt.tm_mon, lt.tm_mday)
    nxt = day + timedelta(days=1)
    start = time.mktime((day.year, day.month, day.day, 0, 0, 0, 0, 0, -1))
    end = time.mktime((nxt.year, nxt.month, nxt.day, 0, 0, 0, 0, 0, -1))
    return (day.isoformat(), datetime.fromtimestamp(start, timezone.utc),
            datetime.fromtimestamp(end, timezone.utc))


# --- rates ----------------------------------------------------------------------
def load_fixture():
    path = os.environ.get("RDC_FIXTURE", "")
    if not path:
        return None
    try:
        with open(path, encoding="utf-8") as fh:
            doc = json.load(fh)
    except (OSError, ValueError) as exc:
        note("fixture unreadable: %s" % exc)
        sys.exit(EXIT_USAGE)
    if not isinstance(doc, dict) or not isinstance(doc.get("repos"), list):
        note("fixture must be an object with a 'repos' array")
        sys.exit(EXIT_USAGE)
    return doc


def load_rates(fixture):
    if fixture is not None and "rates" in fixture:
        return ledger.rates_from_doc(fixture["rates"], "fixture rates")
    return ledger.parse_rates(os.environ.get("RDC_PRICING") or None)


def per_review_rate(rates):
    """The block's per-review USD figure for PLATFORM, or None."""
    usd = (rates or {}).get("usd", {}) if rates else {}
    if PLATFORM == "bugbot":
        return usd.get("bugbot")
    if PLATFORM == "greptile":
        credits = rates.get("credits_per_review") if rates else None
        rate = usd.get("greptile")
        return rate * credits if rate is not None and credits is not None else None
    return None   # coderabbit is priced from its own receipts


def platform_notes(notes):
    for n in notes:
        if PLATFORM in n or n.startswith("rates unavailable"):
            note(n)


# --- the live read ----------------------------------------------------------------
QUERY = """
query($owner: String!, $name: String!, $endCursor: String) {
  repository(owner: $owner, name: $name) {
    pullRequests(first: %d, after: $endCursor, orderBy: {field: UPDATED_AT, direction: DESC}) {
      pageInfo { hasNextPage endCursor }
      nodes {
        number
        updatedAt
        %s
      }
    }
  }
}
"""
# BugBot's runs hang off commits; receipts and triggers off conversation
# comments. Each platform reads only what prices it.
BUGBOT_FIELDS = """commits(last: %d) {
          totalCount
          nodes { commit { checkSuites(first: 5, filterBy: {checkName: "%s"}) {
            nodes { app { slug }
                    checkRuns(first: 20, filterBy: {checkName: "%s", checkType: ALL}) {
                      nodes { databaseId name startedAt } } } } } }
        }""" % (COMMITS_READ, ledger.BUGBOT_CHECK_NAME, ledger.BUGBOT_CHECK_NAME)
COMMENT_FIELDS = """comments(first: %d) {
          totalCount
          nodes { author { __typename login } body createdAt updatedAt }
        }""" % COMMENTS_READ


def gh_graphql(repo, cursor):
    owner, name = repo.split("/", 1)
    fields = BUGBOT_FIELDS if PLATFORM == "bugbot" else COMMENT_FIELDS
    args = ["gh", "api", "graphql", "-f", "query=%s" % (QUERY % (PR_PAGE, fields)),
            "-f", "owner=%s" % owner, "-f", "name=%s" % name]
    if cursor:
        args += ["-f", "endCursor=%s" % cursor]
    try:
        proc = subprocess.run(args, capture_output=True, text=True, timeout=GH_TIMEOUT)
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise Unknown("gh could not read %s: %s" % (repo, exc))
    if proc.returncode != 0:
        raise Unknown("gh api graphql failed for %s (rc=%d): %s"
                      % (repo, proc.returncode, proc.stderr.strip()[:300]))
    try:
        page = json.loads(proc.stdout)
    except ValueError:
        raise Unknown("gh api graphql returned unparseable JSON for %s" % repo)
    if not isinstance(page, dict) or page.get("errors"):
        raise Unknown("gh api graphql returned errors for %s: %s"
                      % (repo, json.dumps(page.get("errors") if isinstance(page, dict) else page)[:300]))
    pulls = (((page.get("data") or {}).get("repository") or {}).get("pullRequests"))
    if not isinstance(pulls, dict) or not isinstance(pulls.get("nodes"), list):
        raise Unknown("gh api graphql returned no pull requests for %s" % repo)
    return pulls


def normalize_pr(node):
    """One GraphQL PR node in measure.sh's normalized shape."""
    pr = {"number": node.get("number"), "updated_at": node.get("updatedAt"),
          "check_runs": [], "issue_comments": [], "partial": []}
    commits = node.get("commits")
    if isinstance(commits, dict):
        if (commits.get("totalCount") or 0) > COMMITS_READ:
            pr["partial"].append("only its last %d of %d commits" % (COMMITS_READ, commits["totalCount"]))
        for c in commits.get("nodes") or []:
            suites = (((c or {}).get("commit") or {}).get("checkSuites") or {}).get("nodes") or []
            for suite in suites:
                slug = ((suite or {}).get("app") or {}).get("slug")
                for run in ((suite or {}).get("checkRuns") or {}).get("nodes") or []:
                    run = run or {}
                    pr["check_runs"].append({"id": run.get("databaseId"), "name": run.get("name"),
                                             "app": slug, "started_at": run.get("startedAt")})
    comments = node.get("comments")
    if isinstance(comments, dict):
        if (comments.get("totalCount") or 0) > COMMENTS_READ:
            pr["partial"].append("only its first %d of %d comments" % (COMMENTS_READ, comments["totalCount"]))
        for c in comments.get("nodes") or []:
            author = (c or {}).get("author") or {}
            login = author.get("login") or ""
            # GraphQL bot logins carry no [bot] suffix; the ledger keys on it
            # (measure.sh's fetch_threads adds it the same way).
            if author.get("__typename") == "Bot" and login and not login.endswith("[bot]"):
                login += "[bot]"
            pr["issue_comments"].append({"user": login, "body": (c or {}).get("body") or "",
                                         "created_at": (c or {}).get("createdAt"),
                                         "updated_at": (c or {}).get("updatedAt")})
    return pr


def read_repo(repo, since):
    """Every PR in `repo` updated at or after `since`, normalized."""
    prs, cursor = [], None
    for _ in range(MAX_PAGES):
        pulls = gh_graphql(repo, cursor)
        older = False
        for node in pulls["nodes"]:
            updated = ledger.parse_ts((node or {}).get("updatedAt"))
            if updated is None:
                raise Unknown("a pull request in %s has no updatedAt" % repo)
            if updated < since:
                older = True
                break
            prs.append(normalize_pr(node))
        info = pulls.get("pageInfo") or {}
        if older or not info.get("hasNextPage"):
            return prs
        cursor = info.get("endCursor")
        if not cursor:
            raise Unknown("gh api graphql gave %s a next page without a cursor" % repo)
    note("%s: more than %d PRs were updated today; only the newest %d were read, so "
         "its spend is a floor" % (repo, PR_PAGE * MAX_PAGES, PR_PAGE * MAX_PAGES))
    return prs


def registered_repos():
    helper = os.environ.get("RDC_REVIEW_REPOS", "")
    if not helper:
        raise Unknown("review-repos.sh not found (checked all three paths) — "
                      "the registered repos cannot be listed")
    try:
        proc = subprocess.run([helper], capture_output=True, text=True, timeout=GH_TIMEOUT)
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise Unknown("review-repos.sh could not run: %s" % exc)
    if proc.returncode != 0:
        raise Unknown("review-repos.sh could not resolve the registered repos (rc=%d)%s"
                      % (proc.returncode, ": " + proc.stderr.strip()[:300] if proc.stderr.strip() else ""))
    repos = [line.strip() for line in proc.stdout.splitlines() if line.strip()]
    if not repos:
        raise Unknown("review-repos.sh listed no repos")
    return repos


# --- the tally --------------------------------------------------------------------
def tally(repos_prs, rates, start, end):
    """Today's spend (Decimal) for PLATFORM from [(repo, [normalized PR])]."""
    comments, runs = [], []
    for repo, prs in repos_prs:
        if not isinstance(prs, list):
            raise Unknown("%s has no 'prs' array" % repo)
        for pr in prs:
            if not isinstance(pr, dict):
                raise Unknown("%s has a malformed PR entry" % repo)
            for why in pr.get("partial") or []:
                note("%s#%s: read %s, so its spend is a floor" % (repo, pr.get("number"), why))
            for c in pr.get("issue_comments") or []:
                if isinstance(c, dict):
                    tagged = dict(c)
                    tagged["pr"] = pr.get("number")
                    comments.append(tagged)
            runs.append(pr.get("check_runs") or [])
    if PLATFORM == "bugbot":
        kept, undated = ledger.filter_between(ledger.bugbot_runs(runs), start, end, "started_at")
        signals, what = {"bugbot_runs": len(kept)}, "Cursor Bugbot check-run(s)"
    elif PLATFORM == "coderabbit":
        kept, undated = ledger.filter_between(ledger.extract_charges(comments), start, end, "at")
        signals, what = {"charges": [e["amount"] for e in kept]}, "CodeRabbit receipt(s)"
    else:
        kept, undated = ledger.filter_between(ledger.greptile_triggers(comments), start, end, "created_at")
        signals, what = {"greptile_triggers": len(kept)}, "@greptileai trigger comment(s)"
    if undated:
        note("%d %s carried no timestamp and were left out, so the tally is a floor" % (undated, what))
    usd, _label = ledger.compute_spend(PLATFORM, signals, rates, 1)
    if usd is None:
        raise Unknown("the %s rate is null or unusable in the review-stack-rates block, so "
                      "today's spend cannot be priced" % PLATFORM)
    return usd


def cache_path(day):
    base = os.environ.get("RDC_CACHE_DIR", "")
    return os.path.join(base, "%s-%s.json" % (PLATFORM, day)) if base else ""


def cache_read(day, now):
    path = cache_path(day)
    if not path:
        return None
    try:
        with open(path, encoding="utf-8") as fh:
            doc = json.load(fh)
        fetched = float(doc["fetched_at"])
        spent = doc["spent_usd"]
        if doc.get("platform") != PLATFORM or doc.get("date") != day or spent is None:
            return None
        if not (0 <= now - fetched < TTL_SECONDS):
            return None
        return ledger.to_decimal(spent)
    except (OSError, ValueError, KeyError, TypeError):
        return None


def cache_write(day, now, spent, repos):
    path = cache_path(day)
    if not path:
        return
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".%s-" % PLATFORM)
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump({"platform": PLATFORM, "date": day, "spent_usd": ledger.to_number(spent),
                       "fetched_at": now, "repos": repos}, fh)
        os.replace(tmp, path)
    except OSError as exc:
        note("could not write the tally cache (%s); the next call reads GitHub again" % exc)


def money(value):
    """Decimal -> the shortest JSON number for its cents (10, 4.74, 7.9), so
    every jq version prints the same text; None -> null."""
    if value is None:
        return None
    value = ledger.cents(value)
    return int(value) if value == value.to_integral_value() else float(value)


def emit(day, spent, cap):
    if spent is None:
        status = "unknown"
    elif spent + ADD > cap:
        status = "over"
    else:
        status = "ok"
    print(json.dumps({"platform": PLATFORM, "date": day,
                      "spent_usd": money(spent), "add_usd": money(ADD),
                      "cap_usd": money(cap), "status": status},
                     separators=(",", ":")))
    return 1 if status == "over" else 0


def main():
    fixture = load_fixture()
    if MODE == "rate":
        rates, notes = load_rates(fixture)
        rate = per_review_rate(rates)
        if rate is not None:
            print(ledger.cents(rate))
            return 0
        fallback = os.environ.get("RDC_FALLBACK_RATE", "")
        if fallback:
            platform_notes(notes)
            note("no usable %s rate in the review-stack-rates block — using the fallback %s"
                 % (PLATFORM, fallback))
            print(ledger.cents(Decimal(fallback)))
        else:
            note("%s has no per-review rate%s — printing 0, so --add-usd 0 asks only whether "
                 "the account is already over" % (PLATFORM, " (receipt-priced)" if PLATFORM == "coderabbit" else ""))
            print("0")
        return 0

    cap = ledger.cents(Decimal(os.environ["RDC_CAP_USD"]))
    now = now_epoch()
    day = TZ_FALLBACK_DAY
    try:
        day, start, end = et_day(now)
        if fixture is not None:
            rates, notes = load_rates(fixture)
            repos_prs = []
            for entry in fixture["repos"]:
                if not isinstance(entry, dict) or not isinstance(entry.get("repo"), str):
                    raise Unknown("a fixture repo entry has no 'repo' name")
                repos_prs.append((entry["repo"], entry.get("prs")))
            if not repos_prs:
                raise Unknown("the fixture lists no repos")
            try:
                spent = tally(repos_prs, rates, start, end)
            except Unknown:
                platform_notes(notes)
                raise
            return emit(day, spent, cap)

        cached = cache_read(day, now)
        if cached is not None:
            return emit(day, cached, cap)
        rates, notes = load_rates(None)
        if PLATFORM != "coderabbit" and per_review_rate(rates) is None:
            platform_notes(notes)
            raise Unknown("the %s rate is null or unusable in the review-stack-rates block, so "
                          "today's spend cannot be priced" % PLATFORM)
        repos = registered_repos()
        repos_prs = [(repo, read_repo(repo, start)) for repo in repos]
        spent = tally(repos_prs, rates, start, end)
        cache_write(day, now, spent, repos)
        return emit(day, spent, cap)
    except Unknown as exc:
        note("unknown — %s (fails open: the trigger may post)" % exc)
        return emit(day, None, cap)


TZ_FALLBACK_DAY = os.environ.get("RDC_ET_TODAY", "")
sys.exit(main())
PY

OUT="$(
  RDC_MODE="$MODE" \
  RDC_PLATFORM="$PLATFORM" \
  RDC_ADD_USD="$ADD_USD" \
  RDC_CAP_USD="$CAP_USD" \
  RDC_FIXTURE="$FIXTURE" \
  RDC_LIB_DIR="$(dirname "$LIB_PY")" \
  RDC_PRICING="$PRICING" \
  RDC_REVIEW_REPOS="$REVIEW_REPOS_SH" \
  RDC_FALLBACK_RATE="$FALLBACK_RATE" \
  RDC_CACHE_DIR="${HOME:+$HOME/.claude/review-daily-cap}" \
  RDC_ET_TODAY="$(et_today)" \
  python3 -c "$PY_SRC"
)"
RC=$?
case "$RC" in
  0|1)
    if [[ "$OUT" == "{"* || ( "$MODE" == "rate" && -n "$OUT" ) ]]; then
      printf '%s\n' "$OUT"
      exit "$RC"
    fi
    ;;
  2) exit 2 ;;
esac
[[ "$MODE" == "rate" ]] && emit_fallback_rate "the rate lookup failed (rc=$RC)"
emit_unknown "the tally failed (rc=$RC)"
