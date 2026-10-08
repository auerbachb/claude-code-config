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
#   Limit-shaped language that no declared pattern explains is reported in
#   `unclassified[]` — NEVER silently counted as healthy. That holds per SIGNAL,
#   not per comment: a body whose declared phrase matched is still probed for
#   anything the match does not account for (#1342). A stale phrase table that
#   quietly reads "active" for a capped tool would defeat the whole audit, so
#   the failure is made visible instead.
#
# USAGE
#   measure.sh [--repo owner/name | --repos a/b,c/d | --all-repos]
#              [--since YYYY-MM-DD [--until YYYY-MM-DD] | --days N] [--limit N]
#              [--ledger] [--pricing <file>]
#              [--fixture <path>] [--json | --summary]
#   measure.sh --help | -h
#
#   --repo      Repo to measure. Default: gh's current-repo inference.
#   --repos     Measure several repos in one run (issue #1808): comma-separated
#               owner/name list. Output is the MULTI-REPO shape below.
#   --all-repos Measure every registered repo, as listed by review-repos.sh
#               (REVIEW_REPOS env, then ~/.claude/account-config.md's
#               `## Review repos`, then ac-gate.yml discovery; with --fixture,
#               discovery is skipped so the run stays offline). If it cannot
#               resolve the list, nothing is measured: exit 1.
#               --repo, --repos and --all-repos are mutually exclusive (exit 2).
#   --since     Window start, inclusive (YYYY-MM-DD). Default: --days 30.
#   --until     Window end, inclusive (YYYY-MM-DD; issue #1809). Valid only with
#               --since, and not before it (exit 2). Bounds the PR search to
#               merged:SINCE..UNTIL and window.days to the inclusive day count.
#               Without it the window and search are exactly as before.
#   --days      Window start as N days before today. Mutually exclusive
#               with --since.
#   --limit     Max merged PRs to sample in the window (default 60), per repo.
#               The window is the measurement's meaning, so a truncated sample is
#               declared in `window.truncated` rather than passed off as the
#               whole window.
#   --ledger    Add labelled spend per tool (issue #1809; see SPEND LEDGER).
#               Implied by every multi-repo run: --repos, --all-repos, or a
#               multi-repo fixture read with no repo flag. Without it, the
#               single-repo path runs the same queries and emits the same
#               output as before.
#   --pricing   Markdown file holding the `review-stack-rates` block (ledger
#               mode only, exit 2 otherwise; unreadable: exit 1). Default: this
#               checkout's .claude/reference/pricing-matrix.md, then the
#               published copies. If none resolves, rate-priced tools read null.
#   --fixture   Read a pre-captured bundle instead of calling gh. Same code path,
#               so tests exercise the real classifier. Shape: FIXTURE FORMAT.
#   --json      Full snapshot on stdout (DEFAULT).
#   --summary   One `tool<TAB>state<TAB>prs<TAB>findings<TAB>sole` line per tool;
#               ledger mode appends `<TAB>spend_usd<TAB>spend_source` (null
#               prints as `null`).
#               Multi-repo: one block per repo headed `# repo: owner/name`, then
#               one `# total: N repos` block, blocks separated by a blank line.
#
# SPEND LEDGER (--ledger)
#   Each tool gains `spend_usd` (number or null) and `spend_source`, one of:
#     receipt   CodeRabbit: the sum of `Charged: $X` lines in coderabbitai[bot]
#               conversation comments in the window, each timed by its comment's
#               last edit (updated_at, else created_at). A FLOOR, never the bill —
#               a summary comment keeps one receipt and a later review overwrites it.
#     estimate  BugBot: `Cursor Bugbot` check-runs published by the `cursor`
#               app (every commit of each PR, filter=all, deduped by run id,
#               timed by started_at) x $/review.
#               Greptile: non-bot `@greptileai` comments x credits/review x $/credit
#               (credits/review absent or null: `none`, never an assumed 1).
#     flat      CodeAnt and Vercel: the monthly fee x elapsed days / 30 —
#               spend so far, never a projection. With --until: the days from
#               --since through the earlier of --until and today, inclusive, so
#               a window wholly in the future bills 0.00 and one straddling
#               today bills its elapsed part. Without it: window.days, whole
#               elapsed days (a --since of today, or later, prorates to 0.00).
#     none      No figure: the rate is null, missing, or unreadable. spend_usd is
#               then null, never 0, and a note names the missing input.
#   Events are kept inside the inclusive window (since 00:00:00Z through until
#   23:59:59Z; no upper bound without --until); an event with no timestamp is
#   left out and counted in a note. Receipts and estimates cover only the PRs
#   this run samples — merged in the window, up to --limit — so reviews of open,
#   closed-unmerged, or later-merged PRs are not counted: they are a floor on
#   the window's account spend, never the whole of it. Rates come only from
#   the fenced `review-stack-rates` block (--pricing). The money rules live in
#   .claude/scripts/lib/review_ledger.py, imported only in ledger mode.
#   Multi-repo: a flat fee is account-level, so each repo gets a share by that
#   tool's prs_touched (even split when all are zero) and the shares sum to the
#   prorated fee to the cent; each total spend_usd is the sum of the per-repo
#   figures, and any null per-repo figure makes the total null. A single-repo
#   ledger run attributes the whole prorated fee to its one repo.
#   The vendor dashboard stays the authority for the real bill. Live ledger runs
#   cost one extra gh call per PR plus one per commit.
#
# FIXTURE FORMAT
#   {"repo": "owner/name",
#    "prs": [{"number": 1, "merged_at": "...",
#             "reviews":        [{"user": "coderabbitai[bot]", "state": "APPROVED", "body": ""}],
#             "pr_comments":    [{"user": "coderabbitai[bot]", "body": ""}],
#             "issue_comments": [{"user": "coderabbitai[bot]", "body": ""}]}]}
#
#   Ledger fields (optional, read only in ledger mode): `created_at` and
#   `updated_at` on an issue comment (a receipt is timed by `updated_at` when
#   present), and a per-PR `check_runs` list of
#   {"id", "name": "Cursor Bugbot", "app": "cursor", "started_at"} objects (REST
#   envelopes with a `check_runs` array, and REST's {"app": {"slug"}}, are
#   accepted too). A run under that name from any other app, or with no `app`,
#   is not BugBot's and is not priced. A PR without `check_runs` has none.
#
#   Multi-repo: {"repos": [{"repo": "owner/name", "truncated": false,
#                           "prs": [ ...as above... ]}]}
#   `truncated` (optional) stands in for a live listing that hit --limit. A
#   multi-repo fixture with neither --repos nor --all-repos measures every repo
#   it carries; with either, each named repo must be present in it (exit 1).
#   A multi-repo fixture cannot be read with --repo, nor a single-repo fixture
#   in multi-repo mode (exit 1).
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
#                "sole_provider_on", "cap_signals": [...], "cap_kinds": [...],
#                "spend_usd", "spend_source"}],   # spend_*: ledger mode only
#     "unclassified": [{"tool", "pr", "token", "excerpt"}],
#     "unclassified_hits": N,   # bodies (review body, inline comment, or
#                               # conversation comment) carrying >=1 unexplained
#                               # limit-shaped token, before the (tool, token)
#                               # dedup that collapses `unclassified` itself
#     "notes": [...]
#   }
#
# OUTPUT (--json, multi-repo: --repos / --all-repos / a multi-repo fixture)
#   {
#     "generated_at", "source",
#     "repos": ["owner/name", ...],
#     "per_repo": [<the single-repo document above, one per repo>],
#     "window": {"since", "until", "days", "limit",
#                "pr_count",        # summed across repos
#                "truncated"},      # true if ANY repo truncated
#     "tools": [...],   # the cross-repo TOTAL per tool, same fields as above, so
#                       # drift.sh reads it unchanged. Counts are summed;
#                       # cap_signals[].pr is repo-qualified "owner/name#N";
#                       # cap_kinds is the union; plan_observed is the first
#                       # repo's non-null value (a disagreement is noted);
#                       # sole_provider_prs lists the "owner/name#N" PRs behind
#                       # sole_provider_on, which stays a count.
#     "unclassified": [...],        # merged, `pr` repo-qualified
#     "unclassified_hits": N,       # summed
#     "notes": ["owner/name: <note>", ...]   # merged, each tagged with its repo;
#                                            # run-wide notes (plan disagreement,
#                                            # ledger rates) follow, untagged
#   }
#
# EXIT STATUS
#   0  Snapshot emitted.
#   1  Measurement failed (gh/network/fixture unreadable, or any one repo of a
#      multi-repo run). Nothing is emitted — a partial snapshot must never
#      become the baseline a later run trusts.
#   2  Usage error.
#
# EXAMPLES
#   .claude/skills/review-stack-audit/measure.sh --days 30 --summary
#   .claude/skills/review-stack-audit/measure.sh --since 2026-06-27 | jq '.tools[]'
#   .claude/skills/review-stack-audit/measure.sh --all-repos --days 7 --summary
#   .claude/skills/review-stack-audit/measure.sh --ledger --since 2026-10-01 --until 2026-10-31 --summary

set -euo pipefail
printf '%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$(basename "$0")" "${*//$'\n'/ }" 2>/dev/null >> "${HOME:-/tmp}/.claude/script-usage.log" || true

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
REPOS_CSV=""
ALL_REPOS=0
SINCE=""
UNTIL=""
DAYS=""
LIMIT="60"
FIXTURE=""
LEDGER=0
PRICING=""

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
    --repos)
      [[ $# -ge 2 && -n "$2" ]] || usage_error "--repos requires a value"
      REPOS_CSV="$2"; shift 2 ;;
    --repos=*)
      REPOS_CSV="${1#--repos=}"; [[ -n "$REPOS_CSV" ]] || usage_error "--repos value cannot be empty"; shift ;;
    --all-repos) ALL_REPOS=1; shift ;;
    --since)
      [[ $# -ge 2 && -n "$2" ]] || usage_error "--since requires a value"
      SINCE="$2"; shift 2 ;;
    --since=*)
      SINCE="${1#--since=}"; [[ -n "$SINCE" ]] || usage_error "--since value cannot be empty"; shift ;;
    --until)
      [[ $# -ge 2 && -n "$2" ]] || usage_error "--until requires a value"
      UNTIL="$2"; shift 2 ;;
    --until=*)
      UNTIL="${1#--until=}"; [[ -n "$UNTIL" ]] || usage_error "--until value cannot be empty"; shift ;;
    --ledger) LEDGER=1; shift ;;
    --pricing)
      [[ $# -ge 2 && -n "$2" ]] || usage_error "--pricing requires a value"
      PRICING="$2"; shift 2 ;;
    --pricing=*)
      PRICING="${1#--pricing=}"; [[ -n "$PRICING" ]] || usage_error "--pricing value cannot be empty"; shift ;;
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
# --repo picks the single-repo shape; --repos/--all-repos pick the multi-repo
# one. Accepting both would make the output shape depend on which flag "won".
if [[ -n "$REPO" ]] && [[ -n "$REPOS_CSV" || "$ALL_REPOS" -eq 1 ]]; then
  usage_error "--repo is mutually exclusive with --repos and --all-repos"
fi
[[ -n "$REPOS_CSV" && "$ALL_REPOS" -eq 1 ]] && usage_error "--repos and --all-repos are mutually exclusive"
REPOS_LIST=""
if [[ -n "$REPOS_CSV" ]]; then
  # Same shape review-repos.sh enforces: the name lands in a gh api path, so a
  # `.`/`..` name (or a dotted owner) is refused rather than sent.
  repo_re='^[A-Za-z0-9][A-Za-z0-9_-]*/[A-Za-z0-9_.-]+$'
  # Newlines separate too: `read` stops at the first one, so a pasted
  # one-per-line list would otherwise lose every repo after the first, silently.
  IFS=',' read -r -a _repos_arr <<< "${REPOS_CSV//$'\n'/,}"
  for _r in ${_repos_arr[@]+"${_repos_arr[@]}"}; do
    # Trim the ends only. Stripping ALL whitespace would quietly turn a typo
    # like "acme/my repo" into a different, valid-looking repo name.
    _r="${_r#"${_r%%[![:space:]]*}"}"
    _r="${_r%"${_r##*[![:space:]]}"}"
    # A blank entry ("a/b,,c/d", a trailing comma) is a separator artefact,
    # not a repo; an all-blank list is still refused below.
    [[ -n "$_r" ]] || continue
    [[ "$_r" =~ $repo_re && "${_r#*/}" != "." && "${_r#*/}" != ".." ]] \
      || usage_error "--repos entry is not owner/name: '$_r'"
    REPOS_LIST+="$_r"$'\n'
  done
  [[ -n "$REPOS_LIST" ]] || usage_error "--repos names no repo"
fi
[[ -z "$DAYS"  ]] || [[ "$DAYS"  =~ ^[0-9]+$ ]] || usage_error "--days must be a non-negative integer"
# Positive, not merely non-negative: `gh pr list --limit 0` fails with its own
# opaque error, and a zero-PR "measurement" is not a window worth reporting.
[[ "$LIMIT" =~ ^[0-9]+$ ]] && [[ "$LIMIT" -gt 0 ]] || usage_error "--limit must be a positive integer"
[[ -z "$SINCE" ]] || [[ "$SINCE" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || usage_error "--since must be YYYY-MM-DD"
# --until closes a window --since opened. Alone it would pair an explicit end
# with a start derived from today's clock — a window nobody asked for.
if [[ -n "$UNTIL" ]]; then
  [[ -n "$SINCE" ]] || usage_error "--until is valid only with --since"
  [[ "$UNTIL" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || usage_error "--until must be YYYY-MM-DD"
  # Same fixed-width YYYY-MM-DD shape, so string order is date order.
  [[ ! "$UNTIL" < "$SINCE" ]] || usage_error "--until ($UNTIL) is before --since ($SINCE)"
fi
# Ledger mode (issue #1809): asked for, or implied by a multi-repo run, whose
# cross-repo total is what the account is billed against. A multi-repo fixture
# ('repos' array) read with no repo flag is measured as a multi-repo run too,
# so it is a ledger run like --repos; --repo against one is refused later.
[[ -n "$REPOS_CSV" || "$ALL_REPOS" -eq 1 ]] && LEDGER=1
if [[ "$LEDGER" -eq 0 && -n "$FIXTURE" && -z "$REPO" && -r "$FIXTURE" ]] \
   && python3 -c 'import json, sys; d = json.load(open(sys.argv[1])); sys.exit(0 if isinstance(d, dict) and "repos" in d else 1)' \
        "$FIXTURE" 2>/dev/null; then
  LEDGER=1
fi
if [[ -n "$PRICING" ]]; then
  [[ "$LEDGER" -eq 1 ]] || usage_error "--pricing is valid only in ledger mode (--ledger, --repos or --all-repos)"
  [[ -r "$PRICING" && -f "$PRICING" ]] || { echo "measure.sh: pricing file not readable: $PRICING" >&2; exit 1; }
fi
[[ -z "$FIXTURE" ]] || [[ -r "$FIXTURE" ]] || { echo "measure.sh: fixture not readable: $FIXTURE" >&2; exit 1; }

if [[ -z "$FIXTURE" ]]; then
  command -v gh >/dev/null 2>&1 || { echo "measure.sh: gh not found (or pass --fixture)" >&2; exit 1; }
fi
command -v python3 >/dev/null 2>&1 || { echo "measure.sh: python3 not found" >&2; exit 1; }

# --all-repos: the registered list. review-repos.sh never returns a partial
# list, and its failure is this run's failure — measuring "whatever resolved"
# would understate every tool's account-level draw without saying so.
if [[ "$ALL_REPOS" -eq 1 ]]; then
  REVIEW_REPOS_SH=""
  # This checkout's own copy first (`cd -P` resolves the published
  # ~/.claude/skills symlink to the worktree), then the published locations.
  _scripts_dir="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd)/scripts" || _scripts_dir=""
  for _c in \
    ${_scripts_dir:+"$_scripts_dir/review-repos.sh"} \
    "$HOME/.claude/skills-worktree/.claude/scripts/review-repos.sh" \
    "$HOME/.claude/scripts/review-repos.sh" \
    ".claude/scripts/review-repos.sh"; do
    if [[ -x "$_c" ]]; then REVIEW_REPOS_SH="$_c"; break; fi
  done
  [[ -n "$REVIEW_REPOS_SH" ]] \
    || { echo "ERROR: review-repos.sh not found (checked this checkout's .claude/scripts and all three published paths) — --all-repos unavailable" >&2; exit 1; }
  # Under --fixture the run must stay offline, so the registered list may come
  # from REVIEW_REPOS or the account config, but never from a live gh
  # discovery: --no-discovery makes that case an exit 1 instead.
  _rr_args=()
  [[ -z "$FIXTURE" ]] || _rr_args+=(--no-discovery)
  REPOS_LIST="$("$REVIEW_REPOS_SH" ${_rr_args[@]+"${_rr_args[@]}"})" \
    || { echo "measure.sh: review-repos.sh could not resolve the registered repos — nothing measured" >&2; exit 1; }
  [[ -n "$REPOS_LIST" ]] || { echo "measure.sh: review-repos.sh returned no repos — nothing measured" >&2; exit 1; }
fi

MULTI=0
[[ -n "$REPOS_CSV" || "$ALL_REPOS" -eq 1 ]] && MULTI=1

# Ledger mode resolves its library and default rates here, and only here: the
# legacy path never touches either, so neither can break it.
LEDGER_LIB_DIR=""
if [[ "$LEDGER" -eq 1 ]]; then
  # This checkout's own .claude/ first (`cd -P` resolves the published
  # ~/.claude/skills symlink to the worktree), then the published locations.
  _claude_dir="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd)" || _claude_dir=""
  for _c in \
    ${_claude_dir:+"$_claude_dir/scripts/lib"} \
    "$HOME/.claude/skills-worktree/.claude/scripts/lib" \
    "$HOME/.claude/scripts/lib" \
    ".claude/scripts/lib"; do
    if [[ -r "$_c/review_ledger.py" ]]; then LEDGER_LIB_DIR="$_c"; break; fi
  done
  [[ -n "$LEDGER_LIB_DIR" ]] \
    || { echo "ERROR: review_ledger.py not found (checked this checkout's .claude/scripts/lib and all three published paths) — spend ledger unavailable" >&2; exit 1; }
  if [[ -z "$PRICING" ]]; then
    for _c in \
      ${_claude_dir:+"$_claude_dir/reference/pricing-matrix.md"} \
      "$HOME/.claude/skills-worktree/.claude/reference/pricing-matrix.md" \
      "$HOME/.claude/reference/pricing-matrix.md" \
      ".claude/reference/pricing-matrix.md"; do
      if [[ -r "$_c" && -f "$_c" ]]; then PRICING="$_c"; break; fi
    done
    # Not fatal: CodeRabbit's receipts need no rate. Every rate-priced tool
    # then reads null with a note naming why — never 0.
    [[ -n "$PRICING" ]] \
      || echo "DEGRADED: pricing-matrix.md not found (checked this checkout's .claude/reference and all three published paths) — rate-priced spend unavailable, continuing without it" >&2
  fi
fi

MEASURE_MODE="$MODE" \
MEASURE_REPO="$REPO" \
MEASURE_MULTI="$MULTI" \
MEASURE_UNTIL="$UNTIL" \
MEASURE_LEDGER="$LEDGER" \
MEASURE_PRICING="$PRICING" \
MEASURE_LIB_DIR="$LEDGER_LIB_DIR" \
MEASURE_REPOS="$REPOS_LIST" \
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
until_arg = os.environ.get("MEASURE_UNTIL", "")
ledger_mode = os.environ.get("MEASURE_LEDGER", "0") == "1"
pricing_path = os.environ.get("MEASURE_PRICING", "")


def fail(msg):
    print("measure.sh: %s" % msg, file=sys.stderr)
    sys.exit(1)


# The ledger library is imported ONLY in ledger mode (issue #1809), so neither
# its absence nor a fault in it can reach the legacy measurement path.
ledger = None
if ledger_mode:
    sys.path.insert(0, os.environ.get("MEASURE_LIB_DIR", ""))
    try:
        import review_ledger as ledger
    except Exception as exc:  # any import-time fault fails the ledger run closed
        fail("could not import the spend ledger library (review_ledger.py): %s" % exc)


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
#
# It runs on EVERY body, not only on bodies nothing declared matched (#1342).
# Spans a matched declared pattern already explains are excluded first, so the
# declared phrases' own limit-shaped words ("...spend limit", "...subscription")
# never re-enter the report as unknowns.
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
    if until_arg:
        # Inclusive on both ends: --since 2026-10-01 --until 2026-10-31 is 31 days.
        try:
            until_dt = datetime.strptime(until_arg, "%Y-%m-%d").replace(tzinfo=timezone.utc)
        except ValueError:
            fail("--until is not a valid date: %s" % until_arg)
        days = (until_dt - since_dt).days + 1
else:
    days = int(days_arg) if days_arg else 30
    since = (now - timedelta(days=days)).strftime("%Y-%m-%d")
# Without --until the window ends today, exactly as it always has.
until = until_arg or now.strftime("%Y-%m-%d")
# The days a flat fee is prorated over (ledger only; window.days is unchanged).
# Flat spend is spend so far, never a projection: a bounded window counts its
# days from --since through the earlier of --until and today, inclusive, so one
# wholly in the future bills nothing and one straddling today bills only its
# elapsed part. An open window keeps window.days (whole elapsed days).
today = now.strftime("%Y-%m-%d")
if until_arg:
    _fee_end = min(until_dt, datetime.strptime(today, "%Y-%m-%d").replace(tzinfo=timezone.utc))
    fee_days = max((_fee_end - since_dt).days + 1, 0)
else:
    fee_days = 0 if since > today else max(days, 0)
# Search and event window: open-ended above unless --until closed it.
search_range = ("merged:%s..%s" % (since, until_arg)) if until_arg else ("merged:>=%s" % since)

multi_requested = os.environ.get("MEASURE_MULTI", "0") == "1"
repos_requested = []
_seen_requested = set()
for _r in os.environ.get("MEASURE_REPOS", "").split("\n"):
    _r = _r.strip()
    if _r and _r.lower() not in _seen_requested:
        _seen_requested.add(_r.lower())
        repos_requested.append(_r)


# --- gather -------------------------------------------------------------------
# `prs` is normalized to one shape regardless of source, so the classifier below
# runs identically on live data and on a fixture. That is what makes the tests
# exercise the real logic rather than a parallel implementation.
def fetch_prs(repo):
    """Every merged PR in the window for one repo, normalized. Any gh failure is
    fatal (run_gh exits 1), so a multi-repo run can never emit a roll-up that
    quietly left out the repo it failed to read."""
    listed = run_gh([
        "pr", "list", "--repo", repo, "--state", "merged",
        "--search", search_range,
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
        pr = {
            "number": num,
            "merged_at": row.get("mergedAt"),
            "reviews": [{"user": (r.get("user") or {}).get("login", ""),
                         "state": r.get("state", ""),
                         "body": r.get("body") or ""} for r in reviews],
            "pr_comments": [{"user": (c.get("user") or {}).get("login", ""),
                             "body": c.get("body") or ""} for c in pr_comments],
            # created_at places a trigger in the ledger window, updated_at a
            # receipt (CodeRabbit edits its summary in place); the legacy path
            # never reads either and never emits normalized data.
            "issue_comments": [{"user": (c.get("user") or {}).get("login", ""),
                                "body": c.get("body") or "",
                                "created_at": c.get("created_at"),
                                "updated_at": c.get("updated_at")} for c in issue_comments],
        }
        if ledger is not None:
            pr["check_runs"] = fetch_bugbot_runs(repo, num)
        prs.append(pr)
    return prs


def fetch_bugbot_runs(repo, num):
    """Every `Cursor Bugbot` check-run on every commit of one PR (ledger only).

    BugBot posts no receipt, so its runs are the only count to price. Each push
    can be a run, so every commit is read, not just HEAD; `filter=all` keeps
    reruns, which bill again. A run reachable from two commits dedupes by id
    in review_ledger.bugbot_runs."""
    commits = run_gh(["api", "repos/%s/pulls/%d/commits?per_page=100" % (repo, num), "--paginate"])
    runs = []
    for commit in commits:
        sha = commit.get("sha") if isinstance(commit, dict) else None
        if not sha:
            continue
        pages = run_gh(["api", "repos/%s/commits/%s/check-runs?per_page=100&filter=all"
                        "&check_name=Cursor%%20Bugbot" % (repo, sha), "--paginate"])
        if isinstance(pages, dict):
            pages = [pages]
        for run in ledger.bugbot_runs(pages):
            runs.append({"id": run.get("id"), "name": run.get("name"),
                         "head_sha": run.get("head_sha"),
                         "app": (run.get("app") or {}).get("slug"),
                         "started_at": run.get("started_at"),
                         "completed_at": run.get("completed_at")})
    return runs


# --- classify -----------------------------------------------------------------
def measure_repo(repo, source, prs, truncated):
    """One repo's snapshot: the single-repo document, exactly as it has always
    been emitted (a multi-repo run's per_repo[] entries ARE these documents).

    Also returns, per tool key, the PR numbers behind `sole_provider_on`. The
    document reports that figure only as a count — drift.sh reads it as one —
    so the numbers travel beside it for the multi-repo roll-up to qualify."""
    notes = []
    if truncated:
        notes.append(
            "Sample hit the --limit of %d, so the window may extend past what was "
            "measured. Throughput and findings counts are floors, not totals." % limit)

    stats = {}
    for t in TOOLS:
        stats[t["key"]] = {
            "key": t["key"], "login": t["login"], "name": t["name"],
            "prs_touched": 0, "review_objects": 0, "approved": 0,
            "changes_requested": 0, "inline_findings": 0, "issue_comments": 0,
            "sole_provider_on": 0, "plan_observed": None,
            "cap_signals": [], "cap_kinds": [],
            "_pr_ids": set(), "_sole_prs": [],
        }

    unclassified = []
    unclassified_seen = set()
    # Entries are deduped per (tool, token) so one reworded vendor phrase
    # repeated across 30 PRs does not produce 30 rows. But the DEDUPED count is
    # what a human reads when deciding whether a new CAP_SIGNALS entry is
    # warranted, and "1" reads as noise whether it happened once or thirty
    # times. Keep the frequency count so the report can state it: how many
    # BODIES carried unexplained limit-shaped language, which is what "is this
    # a vendor reword or noise?" actually turns on. A body counts once however
    # many tokens it carries.
    #
    # BODIES, not comments: classify_body() is fed review bodies as well as
    # inline and conversation comments, so a comment-only label would misreport
    # a vendor banner posted as a review. Reviews are deliberately in scope — a
    # cap notice is the same signal wherever it is posted — so the unit is
    # named for what is actually tallied rather than narrowed to make an
    # inaccurate name true.
    unclassified_hits = 0

    def classify_body(key, pr_number, body):
        """Record cap signals and plan observations from one comment body."""
        nonlocal unclassified_hits
        if not body:
            return
        low = body.lower()
        matched_patterns = []
        for sig in CAP_SIGNALS:
            if sig["tool"] != key:
                continue
            if sig["pattern"] in low:
                matched_patterns.append(sig["pattern"])
                entry = {"pr": pr_number, "kind": sig["kind"], "pattern": sig["pattern"]}
                # Dedupe per (PR, kind): one capped PR is one observation
                # however many comments the vendor posts about it.
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

        # The probe runs on EVERY body, including one that already matched a
        # declared classifier (issue #1342). Gating it on "nothing matched"
        # meant a banner carrying a declared phrase AND a separate undeclared
        # limit signal recorded only the declared kind, and the undeclared one
        # never reached `unclassified[]` — silent by construction, and worst
        # exactly where the vendor says the most. The #1303 window carries the
        # live case: the org usage-spending-cap sentence rode inside comments
        # that already matched, so the audit's own blind-spot surface could not
        # see it.
        #
        # What the probe must NOT do is re-report the declared phrases
        # themselves: several contain limit-shaped words ("...spend limit",
        # "...subscription"), so every span a matched pattern already explains
        # is excluded first. Spans are located in the same stripped-and-lowered
        # string the probe reads, so the overlap test is exact rather than an
        # offset approximation.
        probe = strip_boilerplate(body)
        probe_low = probe.lower()
        declared_spans = []
        for pattern in matched_patterns:
            pos = probe_low.find(pattern)
            while pos != -1:
                declared_spans.append((pos, pos + len(pattern)))
                pos = probe_low.find(pattern, pos + 1)

        counted = False
        for hit in LIMIT_SHAPED.finditer(probe):
            if any(hit.start() < span_end and span_start < hit.end()
                   for span_start, span_end in declared_spans):
                continue
            # `unclassified_hits` counts BODIES, not raw matches: the note it
            # feeds reads "across N limit-shaped comment(s)/review(s)", and a
            # human weighs it as "how often did a vendor say this". Counting a
            # second token in the same body as a second body would overstate
            # that frequency.
            if not counted:
                counted = True
                unclassified_hits += 1
            token = hit.group(0).lower()
            dedupe_key = (key, token)
            if dedupe_key not in unclassified_seen:
                unclassified_seen.add(dedupe_key)
                excerpt_start = max(0, hit.start() - 60)
                unclassified.append({
                    "tool": key, "pr": pr_number, "token": token,
                    "excerpt": " ".join(probe[excerpt_start:hit.end() + 60].split()),
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
            # Inline diff comments are the cleanest available proxy for "a
            # finding", matching the methodology of the 2026-04 and 2026-06
            # hand audits.
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

        # Sole-provider: the unique-value signal. Only meaningful when exactly
        # one tool posted an inline finding on this PR.
        if len(finders_on_pr) == 1:
            sole = stats[next(iter(finders_on_pr))]
            sole["sole_provider_on"] += 1
            sole["_sole_prs"].append(num)

    tools_out = []
    sole_prs = {}
    for t in TOOLS:
        s = stats[t["key"]]
        s["prs_touched"] = len(s["_pr_ids"])
        del s["_pr_ids"]
        sole_prs[t["key"]] = s.pop("_sole_prs")
        s["cap_kinds"] = sorted({c["kind"] for c in s["cap_signals"]})
        s["observed_state"] = observed_state(s)
        tools_out.append(s)

    if unclassified:
        notes.append(
            "%d distinct (tool, token) pair(s) across %d limit-shaped "
            "comment(s)/review(s) carry language no declared classifier explains — "
            "see `unclassified`. A body can appear here AND be classified: the "
            "probe reports only the part its declared match does not account for, "
            "so a second cap phrase riding in a recognised banner is visible rather "
            "than swallowed. These are NOT counted as caps; a human decides whether "
            "the CAP_SIGNALS table needs a new phrase. The body count is the one to "
            "weigh: a phrase recurring across many PRs is a vendor reword, not "
            "noise."
            % (len(unclassified), unclassified_hits))

    if ledger is not None:
        notes.extend(apply_spend(tools_out, prs))

    snapshot = {
        "generated_at": now.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "repo": repo,
        "source": source,
        "window": {
            "since": since,
            "until": until,
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
    return snapshot, sole_prs


def apply_spend(tools_out, prs):
    """Attach `spend_usd` and `spend_source` to each tool (ledger mode only).

    The rules — what counts as a receipt, a run, a trigger, how a window and a
    rate turn into dollars — all live in review_ledger.py; this only gathers the
    repo's raw events for it. Returns this repo's own notes: events left out of
    spend because no timestamp could place them in the window."""
    comments = []
    check_runs = []
    for pr in prs:
        for c in pr.get("issue_comments", []) or []:
            if isinstance(c, dict):
                tagged = dict(c)
                tagged["pr"] = pr.get("number")
                comments.append(tagged)
        check_runs.append(pr.get("check_runs") or [])
    open_until = until_arg or None
    charges, undated_charges = ledger.filter_window(
        ledger.extract_charges(comments), since, open_until, "at")
    runs, undated_runs = ledger.filter_window(
        ledger.bugbot_runs(check_runs), since, open_until, "started_at")
    triggers, undated_triggers = ledger.filter_window(
        ledger.greptile_triggers(comments), since, open_until, "created_at")
    signals = {"charges": [e["amount"] for e in charges],
               "bugbot_runs": len(runs),
               "greptile_triggers": len(triggers)}
    for s in tools_out:
        usd, label = ledger.compute_spend(s["key"], signals, rates, fee_days)
        s["spend_usd"] = ledger.to_number(usd)
        s["spend_source"] = label
    notes = []
    for count, what in ((undated_charges, "CodeRabbit receipt(s)"),
                        (undated_runs, "Cursor Bugbot check-run(s)"),
                        (undated_triggers, "@greptileai trigger comment(s)")):
        if count:
            notes.append(
                "%d %s carried no timestamp, so no window could hold them; they are "
                "left out of spend_usd, which may be understated." % (count, what))
    return notes


def observed_state(s):
    if s["prs_touched"] == 0:
        return "silent"
    if s["cap_signals"]:
        # `capped` wins over `active`: a tool that reviewed AND hit a limit is
        # the case the audit most needs to see. Its throughput numbers still
        # show what it managed before the cap.
        return "capped"
    return "active"


def summary_lines(tools):
    lines = ["%s\t%s\t%d\t%d\t%d" % (s["key"], s["observed_state"],
                                     s["prs_touched"], s["inline_findings"],
                                     s["sole_provider_on"]) for s in tools]
    if ledger is None:
        return lines
    # Ledger mode appends the spend columns; null stays visibly `null`.
    return ["%s\t%s\t%s" % (line,
                            "null" if s["spend_usd"] is None else "%.2f" % s["spend_usd"],
                            s["spend_source"]) for line, s in zip(lines, tools)]


def qualify(repo, pr_number):
    """A PR identifier that survives leaving its repo: `owner/name#N`."""
    return "%s#%s" % (repo, pr_number)


# Rates are read once per run (ledger mode only). Their notes describe the
# pricing file, not any repo, so they are reported once rather than per repo.
rates, rate_notes = None, []
if ledger is not None:
    rates, rate_notes = ledger.parse_rates(pricing_path)

bundle = None
if fixture:
    try:
        with open(fixture) as fh:
            bundle = json.load(fh)
    except (OSError, ValueError) as exc:
        fail("fixture unreadable: %s" % exc)
    if not isinstance(bundle, dict):
        fail("fixture must be an object with a 'prs' array")
multi_fixture = bundle is not None and "repos" in bundle
# A multi-repo fixture read with no repo flag measures everything it carries;
# --repo against one is refused below rather than guessed at.
multi = multi_requested or (multi_fixture and not repo_arg)

# --- single repo: the shape every existing caller reads ------------------------
if not multi:
    if fixture:
        if multi_fixture:
            fail("a multi-repo fixture ('repos' array) cannot be read with --repo; "
                 "use --repos or --all-repos")
        if not isinstance(bundle.get("prs"), list):
            fail("fixture must be an object with a 'prs' array")
        source = "fixture"
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
        prs = fetch_prs(repo)

    truncated = (not fixture) and len(prs) >= limit
    snapshot, _ = measure_repo(repo, source, prs, truncated)
    if ledger is not None:
        snapshot["notes"].extend(rate_notes)
        snapshot["notes"].append(
            "Flat monthly fees are account-level: this single-repo ledger run "
            "attributes the whole %d-day prorated fee to %s. --repos / --all-repos "
            "split it across repos by each tool's prs_touched." % (fee_days, repo))
    if mode == "summary":
        for line in summary_lines(snapshot["tools"]):
            print(line)
    else:
        print(json.dumps(snapshot, indent=2, sort_keys=True))
    sys.exit(0)

# --- multi repo (issue #1808) --------------------------------------------------
# Every repo is measured before anything is printed, so one failing repo
# (run_gh / fail exit 1 mid-loop) leaves stdout empty: fail closed, as the
# single-repo path always has.
fixture_entries = {}
if fixture:
    if not isinstance(bundle.get("repos"), list):
        fail("multi-repo mode needs a fixture with a 'repos' array")
    fixture_order = []
    for entry in bundle["repos"]:
        if (not isinstance(entry, dict) or not isinstance(entry.get("repo"), str)
                or not entry["repo"] or not isinstance(entry.get("prs"), list)
                or not isinstance(entry.get("truncated", False), bool)):
            fail("fixture 'repos' entries must be objects with a 'repo' name, a "
                 "'prs' array and an optional boolean 'truncated'")
        if entry["repo"].lower() in fixture_entries:
            fail("fixture lists repo %s twice" % entry["repo"])
        fixture_entries[entry["repo"].lower()] = entry
        fixture_order.append(entry["repo"])
    source = "fixture"
    targets = repos_requested or fixture_order
else:
    source = "github"
    targets = repos_requested
if not targets:
    fail("no repos to measure")

results = []
for repo in targets:
    if fixture:
        entry = fixture_entries.get(repo.lower())
        if entry is None:
            fail("repo %s is not in the fixture" % repo)
        prs = entry["prs"]
        truncated = entry.get("truncated", False)
    else:
        prs = fetch_prs(repo)
        truncated = len(prs) >= limit
    doc, sole = measure_repo(repo, source, prs, truncated)
    results.append((repo, doc, sole))

# A flat fee is billed once to the account, not once per repo. Each repo's share
# is that tool's prs_touched share of the one prorated fee, allocated in whole
# cents so the shares sum to the fee exactly (issue #1809). A null rate stays
# null in every repo, which nulls the total below.
if ledger is not None:
    for t in TOOLS:
        if ledger.TOOL_RULES[t["key"]]["method"] != "flat":
            continue
        monthly = rates["usd"].get(t["key"]) if rates else None
        if monthly is None:
            continue
        entries = [next(x for x in doc["tools"] if x["key"] == t["key"]) for _, doc, _ in results]
        shares = ledger.allocate(ledger.prorate_flat(monthly, fee_days),
                                 [e["prs_touched"] for e in entries])
        for entry, share in zip(entries, shares):
            entry["spend_usd"] = ledger.to_number(share)

# The cross-repo total per tool. Same fields as a single-repo tool entry, so
# drift.sh — which reads only `tools[]`, `window.truncated` and `unclassified`
# — compares an account-level total against the baseline with no change.
SUMMED = ["prs_touched", "review_objects", "approved", "changes_requested",
          "inline_findings", "issue_comments", "sole_provider_on"]
totals = []
notes = []
for t in TOOLS:
    agg = {"key": t["key"], "login": t["login"], "name": t["name"],
           "plan_observed": None, "cap_signals": [], "sole_provider_prs": []}
    for field in SUMMED:
        agg[field] = 0
    plans = []
    for repo, doc, sole in results:
        rt = next(x for x in doc["tools"] if x["key"] == t["key"])
        for field in SUMMED:
            agg[field] += rt[field]
        if rt["plan_observed"]:
            plans.append((repo, rt["plan_observed"]))
        for c in rt["cap_signals"]:
            agg["cap_signals"].append({"pr": qualify(repo, c["pr"]),
                                       "kind": c["kind"], "pattern": c["pattern"]})
        agg["sole_provider_prs"].extend(qualify(repo, n) for n in sole[t["key"]])
    if plans:
        agg["plan_observed"] = plans[0][1]
        if len({p for _, p in plans}) > 1:
            # One account can still sit on different plans per repo (a public
            # repo on a vendor's free OSS tier, say). Reporting only the first
            # would hide exactly the billed-state question the audit asks.
            notes.append(
                "%s stated different plans across repos (%s); the total's "
                "plan_observed carries the first, so read per_repo[] before "
                "comparing billed state."
                % (t["name"], "; ".join("%s: %s" % (r, p) for r, p in plans)))
    agg["cap_kinds"] = sorted({c["kind"] for c in agg["cap_signals"]})
    agg["observed_state"] = observed_state(agg)
    if ledger is not None:
        # The total is the sum of the per-repo figures printed beside it, in
        # cents; one null repo makes the total null rather than a quiet partial.
        spend, label = ledger.sum_spend([
            (ledger.to_decimal(rt["spend_usd"]), rt["spend_source"])
            for rt in (next(x for x in doc["tools"] if x["key"] == t["key"])
                       for _, doc, _ in results)])
        agg["spend_usd"] = ledger.to_number(spend)
        agg["spend_source"] = label
    totals.append(agg)
notes.extend(rate_notes)

merged_notes = ["%s: %s" % (repo, n) for repo, doc, _ in results for n in doc["notes"]]
unclassified_all = []
for repo, doc, _ in results:
    for u in doc["unclassified"]:
        qualified = dict(u)
        qualified["pr"] = qualify(repo, u["pr"])
        unclassified_all.append(qualified)

rollup = {
    "generated_at": now.strftime("%Y-%m-%dT%H:%M:%SZ"),
    "source": source,
    "repos": [repo for repo, _, _ in results],
    "per_repo": [doc for _, doc, _ in results],
    "window": {
        "since": since,
        "until": until,
        "days": days,
        "pr_count": sum(doc["window"]["pr_count"] for _, doc, _ in results),
        "limit": limit,
        "truncated": any(doc["window"]["truncated"] for _, doc, _ in results),
    },
    "tools": totals,
    "unclassified": unclassified_all,
    "unclassified_hits": sum(doc["unclassified_hits"] for _, doc, _ in results),
    "notes": merged_notes + notes,
}

if mode == "summary":
    blocks = []
    for repo, doc, _ in results:
        blocks.append("\n".join(["# repo: %s" % repo] + summary_lines(doc["tools"])))
    blocks.append("\n".join(["# total: %d repo%s" % (len(results), "" if len(results) == 1 else "s")]
                            + summary_lines(totals)))
    print("\n\n".join(blocks))
else:
    print(json.dumps(rollup, indent=2, sort_keys=True))
PY
