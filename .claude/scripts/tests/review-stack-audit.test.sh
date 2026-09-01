#!/usr/bin/env bash
# Tests for /review-stack-audit's three engines (issues #1201, #1345):
#   measure.sh     — per-tool measurement and cap classification
#   drift.sh       — snapshot vs baseline comparison
#   report-path.sh — collision-free report destination
#
# Every case is OFFLINE. measure.sh is driven through --fixture, which feeds the
# SAME code path live gh data takes, so these exercise the real classifier
# rather than a parallel reimplementation of it.
#
# HOME is sandboxed to a mktemp tree (script-usage-log-redirect.test.sh
# pattern), so the real ~/.claude is never touched. All three engines append a
# telemetry line to $HOME/.claude/script-usage.log on every invocation, so
# without this the suite would write into the developer's own log — and this
# header used to claim otherwise.
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
MEASURE="$REPO_ROOT/.claude/skills/review-stack-audit/measure.sh"
DRIFT="$REPO_ROOT/.claude/skills/review-stack-audit/drift.sh"
REPORT_PATH="$REPO_ROOT/.claude/skills/review-stack-audit/report-path.sh"
BASELINE_REAL="$REPO_ROOT/.claude/reference/review-stack-baseline.json"

TMP_DIR="$(mktemp -d)"
cleanup() { chmod -R u+w "$TMP_DIR" 2>/dev/null || true; rm -rf "$TMP_DIR"; }
trap cleanup EXIT

# Sandbox HOME before any engine runs. `.claude/` is created so the telemetry
# append still succeeds — the goal is to redirect that write, not to silently
# exercise a different (log-disabled) path than production takes. Set after the
# REPO_ROOT lookup above, which is the suite's only HOME-sensitive command.
export HOME="$TMP_DIR/home"
mkdir -p "$HOME/.claude"

FAILED=0
fail() { echo "FAIL: $*" >&2; FAILED=1; }
ok() { echo "ok   — $*"; }

[[ -x "$MEASURE" ]] || { echo "FAIL: measure.sh missing or not executable" >&2; exit 1; }
[[ -x "$DRIFT"   ]] || { echo "FAIL: drift.sh missing or not executable" >&2; exit 1; }
[[ -x "$REPORT_PATH" ]] || { echo "FAIL: report-path.sh missing or not executable" >&2; exit 1; }

# jq-free field reader: these run wherever python3 does, and python3 is already
# a hard dependency of both scripts under test.
jget() { python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));print(eval(sys.argv[2],{"d":d}))' "$1" "$2"; }

# ---------------------------------------------------------------------------
# Fixture builders — each case builds its own premise rather than sharing a
# blob, so a later edit cannot silently make an earlier case pass for the
# wrong reason.
# ---------------------------------------------------------------------------

# fixture_write <path> <prs-json>
fixture_write() {
  printf '{"repo":"test/repo","prs":%s}' "$2" > "$1"
}

# One PR where each named tool posts one inline finding.
pr_with_finders() {
  local num="$1"; shift
  local comments="" tool
  for tool in "$@"; do
    [[ -n "$comments" ]] && comments+=","
    comments+="{\"user\":\"$tool\",\"body\":\"nit: rename this\"}"
  done
  printf '{"number":%s,"merged_at":"2026-08-01T00:00:00Z","reviews":[],"pr_comments":[%s],"issue_comments":[]}' \
    "$num" "$comments"
}

# ---------------------------------------------------------------------------
# measure.sh — cap classification
# ---------------------------------------------------------------------------

F="$TMP_DIR/caps.json"
fixture_write "$F" '[
 {"number":1,"merged_at":"2026-08-01T00:00:00Z","reviews":[],"pr_comments":[],
  "issue_comments":[
    {"user":"coderabbitai[bot]","body":"<!-- This is an auto-generated comment: rate limited by coderabbit.ai -->"},
    {"user":"codeant-ai[bot]","body":"Go to team management and add this email to the PR Review subscription."},
    {"user":"cursor[bot]","body":"Bugbot is counted against Cursor usage and this run hit a usage or spend limit."}
  ]}]'
OUT="$TMP_DIR/caps.out.json"
"$MEASURE" --fixture "$F" --json > "$OUT" 2>"$TMP_DIR/caps.err" || fail "measure.sh exited non-zero on cap fixture"

for pair in "coderabbit:rate_limit" "codeant:not_subscribed" "bugbot:spend_limit"; do
  key="${pair%%:*}"; kind="${pair##*:}"
  got="$(jget "$OUT" "[t['cap_kinds'] for t in d['tools'] if t['key']=='$key'][0]")"
  case "$got" in
    *"$kind"*) ok "measure: $key classified $kind" ;;
    *) fail "measure: $key expected cap kind $kind, got $got" ;;
  esac
  state="$(jget "$OUT" "[t['observed_state'] for t in d['tools'] if t['key']=='$key'][0]")"
  [[ "$state" == "capped" ]] || fail "measure: $key observed_state expected 'capped', got '$state'"
done
ok "measure: capped state set for all three capped tools"

# Case-insensitivity regression (a real bug found on live data): CodeRabbit
# writes "> **Plan**: Pro" with capital letters. A case-sensitive regex returned
# None here, silently losing the only readable billed-state signal we have.
F="$TMP_DIR/plan.json"
fixture_write "$F" '[
 {"number":1,"merged_at":"2026-08-01T00:00:00Z","reviews":[],"pr_comments":[],
  "issue_comments":[{"user":"coderabbitai[bot]","body":"> **Plan**: Pro\n> **Review profile**: assertive"}]}]'
OUT="$TMP_DIR/plan.out.json"
"$MEASURE" --fixture "$F" --json > "$OUT" || fail "measure.sh failed on plan fixture"
plan="$(jget "$OUT" "[t['plan_observed'] for t in d['tools'] if t['key']=='coderabbit'][0]")"
[[ "$plan" == "pro" ]] && ok "measure: plan tier read from mixed-case '**Plan**: Pro'" \
  || fail "measure: plan_observed expected 'pro', got '$plan'"

# A cap phrase belongs to ONE tool. CodeAnt's subscription wording appearing
# under CodeRabbit's login must not mark CodeRabbit capped.
F="$TMP_DIR/crosstalk.json"
fixture_write "$F" '[
 {"number":1,"merged_at":"2026-08-01T00:00:00Z","reviews":[],"pr_comments":[],
  "issue_comments":[{"user":"coderabbitai[bot]","body":"add this email to the PR Review subscription"}]}]'
OUT="$TMP_DIR/crosstalk.out.json"
"$MEASURE" --fixture "$F" --json > "$OUT" || fail "measure.sh failed on crosstalk fixture"
kinds="$(jget "$OUT" "[t['cap_kinds'] for t in d['tools'] if t['key']=='coderabbit'][0]")"
[[ "$kinds" == "[]" ]] && ok "measure: cap phrases do not cross tool boundaries" \
  || fail "measure: CodeRabbit wrongly took CodeAnt's cap phrase: $kinds"

# CodeRabbit meters two different mechanisms (issue #1303): a per-developer
# per-hour burst allowance, and the Fair Usage trailing-volume degradation.
# Collapsing both into `rate_limit` let the baseline record one expected cap and
# silently cover the other. Each phrase must now produce only its own kind.
F="$TMP_DIR/cr-cap-kinds.json"
fixture_write "$F" '[
 {"number":1,"merged_at":"2026-08-01T00:00:00Z","reviews":[],"pr_comments":[],
  "issue_comments":[{"user":"coderabbitai[bot]","body":"You have reached a temporary PR review limit under our Fair Usage Limits Policy."}]},
 {"number":2,"merged_at":"2026-08-02T00:00:00Z","reviews":[],"pr_comments":[],
  "issue_comments":[{"user":"greptile-apps[bot]","body":"<!-- This is an auto-generated comment: rate limited by coderabbit.ai -->"}]}]'
OUT="$TMP_DIR/cr-cap-kinds.out.json"
"$MEASURE" --fixture "$F" --json > "$OUT" || fail "measure.sh failed on cap-kind fixture"
kinds="$(jget "$OUT" "[t['cap_kinds'] for t in d['tools'] if t['key']=='coderabbit'][0]")"
[[ "$kinds" == "['fair_usage']" ]] \
  && ok "measure: the Fair Usage phrase classifies as fair_usage and nothing else" \
  || fail "measure: Fair Usage phrase expected cap_kinds ['fair_usage'], got $kinds"
# Negative control on the same run: the marker under another tool's login must
# not leak a CodeRabbit kind, so the assertion above cannot pass by accident.
gk="$(jget "$OUT" "[t['cap_kinds'] for t in d['tools'] if t['key']=='greptile'][0]")"
[[ "$gk" == "[]" ]] && ok "measure: CodeRabbit's marker under another login classifies nothing" \
  || fail "measure: greptile wrongly took CodeRabbit's marker: $gk"

# The burst marker alone must still be rate_limit — the split must not have
# moved the pre-existing signal along with the new one.
F="$TMP_DIR/cr-burst-only.json"
fixture_write "$F" '[
 {"number":3,"merged_at":"2026-08-03T00:00:00Z","reviews":[],"pr_comments":[],
  "issue_comments":[{"user":"coderabbitai[bot]","body":"Review limit reached. Next review available in: 12 minutes."}]}]'
OUT="$TMP_DIR/cr-burst-only.out.json"
"$MEASURE" --fixture "$F" --json > "$OUT" || fail "measure.sh failed on burst-only fixture"
kinds="$(jget "$OUT" "[t['cap_kinds'] for t in d['tools'] if t['key']=='coderabbit'][0]")"
[[ "$kinds" == "['rate_limit']" ]] \
  && ok "measure: the burst banner classifies as rate_limit and nothing else" \
  || fail "measure: burst banner expected cap_kinds ['rate_limit'], got $kinds"

# The real banner carries BOTH the machine marker and the Fair Usage sentence in
# one body. The two kinds are not disjoint populations, and a reader who assumes
# they are will mis-add the counts — so pin the co-occurrence rather than leave
# it to be discovered on live data.
F="$TMP_DIR/cr-cap-both.json"
fixture_write "$F" '[
 {"number":4,"merged_at":"2026-08-04T00:00:00Z","reviews":[],"pr_comments":[],
  "issue_comments":[{"user":"coderabbitai[bot]","body":"<!-- This is an auto-generated comment: rate limited by coderabbit.ai -->\n## Review limit reached\nYou have reached a temporary PR review limit under our Fair Usage Limits Policy."}]}]'
OUT="$TMP_DIR/cr-cap-both.out.json"
"$MEASURE" --fixture "$F" --json > "$OUT" || fail "measure.sh failed on combined-banner fixture"
kinds="$(jget "$OUT" "[t['cap_kinds'] for t in d['tools'] if t['key']=='coderabbit'][0]")"
[[ "$kinds" == "['fair_usage', 'rate_limit']" ]] \
  && ok "measure: one banner carrying both signals records both kinds on that PR" \
  || fail "measure: combined banner expected both kinds, got $kinds"

# CodeRabbit also EXPLAINS the Fair Usage policy in ordinary prose, and quotes
# this repo's own cap documentation back at us. Matching the bare policy name
# counted that as a cap (#1338, found live on PR #1292): a tool that was
# answering a pricing question read as a tool that had been throttled. The two
# assertions below are a matched pair and must stay together — the first alone
# would also pass if the classifier stopped recognising Fair Usage entirely.
F="$TMP_DIR/cr-fair-usage-prose.json"
fixture_write "$F" '[
 {"number":5,"merged_at":"2026-08-05T00:00:00Z","reviews":[],"pr_comments":[
   {"user":"coderabbitai[bot]","body":"Key details regarding this quota: these limits function as a rolling allowance rather than a fixed hourly reset, so additional reviews become available as earlier ones age out. CodeRabbit also maintains a Fair Usage Limits Policy, which may adjust review availability for accounts demonstrating sustained, high-volume activity that significantly exceeds typical usage."}],
  "issue_comments":[]}]'
OUT="$TMP_DIR/cr-fair-usage-prose.out.json"
"$MEASURE" --fixture "$F" --json > "$OUT" || fail "measure.sh failed on Fair Usage prose fixture"
kinds="$(jget "$OUT" "[t['cap_kinds'] for t in d['tools'] if t['key']=='coderabbit'][0]")"
[[ "$kinds" == "[]" ]] \
  && ok "measure: prose merely naming the Fair Usage policy is not a cap signal" \
  || fail "measure: Fair Usage prose wrongly classified as a cap: $kinds"
# It must not be silently dropped either — an unrecognised limit-shaped comment
# is surfaced for a human, which is the whole design of unclassified[].
uc="$(jget "$OUT" "[u['tool'] for u in d['unclassified']]")"
[[ "$uc" == "['coderabbit']" ]] \
  && ok "measure: the unmatched Fair Usage prose still surfaces in unclassified[]" \
  || fail "measure: Fair Usage prose expected in unclassified[], got $uc"

# Positive control for the pair above: the REAL refusal wording, with the
# markdown link CodeRabbit actually emits, must still classify as fair_usage.
# Without this, tightening the pattern to nothing would pass the prose case.
F="$TMP_DIR/cr-fair-usage-linked.json"
fixture_write "$F" '[
 {"number":6,"merged_at":"2026-08-06T00:00:00Z","reviews":[],"pr_comments":[],
  "issue_comments":[{"user":"coderabbitai[bot]","body":"Full review finished.\n\n---\n\nYour included review limit is currently reached under our [Fair Usage Limits Policy](https://docs.coderabbit.ai/management/plans#fair-usage-limits-policy). Your current included review allowance is based on your included PR review attempts over the past 7 days."}]}]'
OUT="$TMP_DIR/cr-fair-usage-linked.out.json"
"$MEASURE" --fixture "$F" --json > "$OUT" || fail "measure.sh failed on linked-refusal fixture"
kinds="$(jget "$OUT" "[t['cap_kinds'] for t in d['tools'] if t['key']=='coderabbit'][0]")"
[[ "$kinds" == "['fair_usage']" ]] \
  && ok "measure: the linked Fair Usage refusal clause still classifies as fair_usage" \
  || fail "measure: linked Fair Usage refusal expected ['fair_usage'], got $kinds"
# One body matching both the linked and unlinked patterns is still one PR-level
# observation — the per-(PR, kind) dedupe, pinned so a third pattern cannot
# quietly start double-counting capped PRs.
n="$(jget "$OUT" "len([c for c in [t for t in d['tools'] if t['key']=='coderabbit'][0]['cap_signals'] if c['kind']=='fair_usage'])")"
[[ "$n" == "1" ]] \
  && ok "measure: overlapping fair_usage patterns record one signal per PR" \
  || fail "measure: expected 1 deduped fair_usage signal, got $n"

# ---------------------------------------------------------------------------
# measure.sh — sole-provider, the unique-value signal
# ---------------------------------------------------------------------------

F="$TMP_DIR/sole.json"
fixture_write "$F" "[
 $(pr_with_finders 1 'greptile-apps[bot]'),
 $(pr_with_finders 2 'coderabbitai[bot]' 'codeant-ai[bot]'),
 $(pr_with_finders 3 'coderabbitai[bot]')
]"
OUT="$TMP_DIR/sole.out.json"
"$MEASURE" --fixture "$F" --json > "$OUT" || fail "measure.sh failed on sole fixture"
g="$(jget "$OUT" "[t['sole_provider_on'] for t in d['tools'] if t['key']=='greptile'][0]")"
c="$(jget "$OUT" "[t['sole_provider_on'] for t in d['tools'] if t['key']=='coderabbit'][0]")"
a="$(jget "$OUT" "[t['sole_provider_on'] for t in d['tools'] if t['key']=='codeant'][0]")"
[[ "$g" == "1" && "$c" == "1" && "$a" == "0" ]] \
  && ok "measure: sole_provider counts only PRs where exactly one tool found something" \
  || fail "measure: sole_provider wrong (greptile=$g coderabbit=$c codeant=$a; want 1/1/0)"

# ---------------------------------------------------------------------------
# measure.sh — unclassified surfacing (never silently "healthy")
# ---------------------------------------------------------------------------

F="$TMP_DIR/unclass.json"
fixture_write "$F" '[
 {"number":7,"merged_at":"2026-08-01T00:00:00Z","reviews":[],"pr_comments":[],
  "issue_comments":[{"user":"coderabbitai[bot]","body":"We have exhausted our monthly quota for this integration."}]}]'
OUT="$TMP_DIR/unclass.out.json"
"$MEASURE" --fixture "$F" --json > "$OUT" || fail "measure.sh failed on unclassified fixture"
n="$(jget "$OUT" "len(d['unclassified'])")"
state="$(jget "$OUT" "[t['observed_state'] for t in d['tools'] if t['key']=='coderabbit'][0]")"
[[ "$n" == "1" ]] && ok "measure: limit-shaped comment with no classifier is surfaced" \
  || fail "measure: expected 1 unclassified entry, got $n"
[[ "$state" == "active" ]] && ok "measure: unclassified is NOT counted as a cap" \
  || fail "measure: unclassified wrongly changed observed_state to '$state'"

# Vendor boilerplate mentions limits routinely; it must not flood the report.
F="$TMP_DIR/boiler.json"
fixture_write "$F" '[
 {"number":8,"merged_at":"2026-08-01T00:00:00Z","reviews":[],"pr_comments":[],
  "issue_comments":[{"user":"coderabbitai[bot]","body":"Looks good.\n<details><summary>How do review limits work?</summary>quota subscription billing</details>"}]}]'
OUT="$TMP_DIR/boiler.out.json"
"$MEASURE" --fixture "$F" --json > "$OUT" || fail "measure.sh failed on boilerplate fixture"
n="$(jget "$OUT" "len(d['unclassified'])")"
[[ "$n" == "0" ]] && ok "measure: collapsed vendor boilerplate is stripped before the generic probe" \
  || fail "measure: boilerplate leaked $n unclassified entries"

# A declared match used to suppress the generic probe for the WHOLE body
# (#1342), so a banner carrying a declared phrase AND a separate undeclared
# limit signal recorded only the declared kind — and the unknown one never
# reached the surface whose entire job is to flag phrase-table gaps. The body
# below is the issue's evidence verbatim. Both halves are asserted together:
# the declared kind must survive, and the undeclared token must appear.
F="$TMP_DIR/unclass-plus-declared.json"
fixture_write "$F" '[
 {"number":9,"merged_at":"2026-08-01T00:00:00Z","reviews":[],"pr_comments":[],
  "issue_comments":[{"user":"coderabbitai[bot]","body":"Your included review limit is currently reached under our [Fair Usage Limits Policy](https://docs.coderabbit.ai/management/plans#fair-usage-limits-policy). Separately, your account is out of credits."}]}]'
OUT="$TMP_DIR/unclass-plus-declared.out.json"
"$MEASURE" --fixture "$F" --json > "$OUT" || fail "measure.sh failed on declared-plus-undeclared fixture"
kinds="$(jget "$OUT" "[t['cap_kinds'] for t in d['tools'] if t['key']=='coderabbit'][0]")"
[[ "$kinds" == "['fair_usage']" ]] \
  && ok "measure: a body carrying both signals still records the declared kind" \
  || fail "measure: declared kind lost on combined body, got $kinds"
tok="$(jget "$OUT" "[u['token'] for u in d['unclassified']]")"
[[ "$tok" == "['out of credits']" ]] \
  && ok "measure: the undeclared signal in that same body reaches unclassified[]" \
  || fail "measure: expected ['out of credits'] in unclassified, got $tok"

# The live case this cost us: the org usage-spending-cap sentence rides inside
# comments that already match a declared classifier, so through the #1303 window
# the audit's own blind-spot mechanism could not see it at all
# (review-stack-audit-2026-08.md). It must surface now.
F="$TMP_DIR/unclass-spending-cap.json"
fixture_write "$F" '[
 {"number":10,"merged_at":"2026-08-02T00:00:00Z","reviews":[],"pr_comments":[],
  "issue_comments":[{"user":"coderabbitai[bot]","body":"You have reached a temporary PR review limit under our Fair Usage Limits Policy. Your organization has reached its usage spending cap. Adjust your spending cap in the billing tab."}]}]'
OUT="$TMP_DIR/unclass-spending-cap.out.json"
"$MEASURE" --fixture "$F" --json > "$OUT" || fail "measure.sh failed on spending-cap fixture"
kinds="$(jget "$OUT" "[t['cap_kinds'] for t in d['tools'] if t['key']=='coderabbit'][0]")"
tok="$(jget "$OUT" "[u['token'] for u in d['unclassified']]")"
[[ "$kinds" == "['fair_usage']" && "$tok" == "['billing']" ]] \
  && ok "measure: a third signal inside a classified banner is no longer invisible" \
  || fail "measure: spending-cap case wrong (kinds=$kinds tokens=$tok)"

# NEGATIVE CONTROL for the two cases above, and the reason the probe excludes
# spans a declared pattern already explains. Several declared patterns CONTAIN
# limit-shaped words — "...hit a usage or spend limit", "...PR Review
# subscription" — so simply ungating the probe would report the phrase table
# back to itself as unknown. Measured: with the exclusion removed this same
# fixture yields 2 entries (codeant/subscription, bugbot/spend limit).
OUT="$TMP_DIR/caps-noleak.out.json"
"$MEASURE" --fixture "$TMP_DIR/caps.json" --json > "$OUT" || fail "measure.sh failed re-running cap fixture"
n="$(jget "$OUT" "len(d['unclassified'])")"
hits="$(jget "$OUT" "d['unclassified_hits']")"
[[ "$n" == "0" && "$hits" == "0" ]] \
  && ok "measure: declared patterns do not report their own limit-shaped words as unknown" \
  || fail "measure: purely-declared bodies leaked $n entries / $hits hits"

# unclassified_hits counts BODIES, not raw matches — the note it feeds says
# "across N limit-shaped comment(s)/review(s)" and a human reads it as how often
# a vendor said this. Two unknown tokens in one body are two rows but one body.
F="$TMP_DIR/unclass-two-tokens.json"
fixture_write "$F" '[
 {"number":11,"merged_at":"2026-08-03T00:00:00Z","reviews":[],"pr_comments":[],
  "issue_comments":[{"user":"coderabbitai[bot]","body":"Your included review limit is currently reached under our [Fair Usage Limits Policy](https://docs.coderabbit.ai/management/plans#fair-usage-limits-policy). Your account is out of credits; see the billing tab."}]}]'
OUT="$TMP_DIR/unclass-two-tokens.out.json"
"$MEASURE" --fixture "$F" --json > "$OUT" || fail "measure.sh failed on two-token fixture"
n="$(jget "$OUT" "len(d['unclassified'])")"
hits="$(jget "$OUT" "d['unclassified_hits']")"
[[ "$n" == "2" && "$hits" == "1" ]] \
  && ok "measure: two unknown tokens in one comment count as one comment" \
  || fail "measure: expected 2 entries / 1 hit, got $n / $hits"

# classify_body() is fed REVIEW bodies as well as comments (CodeAnt, PR #1490),
# so the tally is over bodies, not comments. A vendor cap notice posted as a
# review body must count exactly like the same text posted as a comment —
# narrowing the probe to comments to make a "comment count" label true would
# reintroduce the #1342 blind spot on a different axis. Every other fixture here
# leaves "reviews" empty, so without this case the review path is unpinned.
F="$TMP_DIR/unclass-review-body.json"
fixture_write "$F" '[
 {"number":12,"merged_at":"2026-08-04T00:00:00Z","pr_comments":[],"issue_comments":[],
  "reviews":[{"user":"greptile-apps[bot]","state":"COMMENTED","body":"Skipping review: this org has exhausted its monthly quota."}]}]'
OUT="$TMP_DIR/unclass-review-body.out.json"
"$MEASURE" --fixture "$F" --json > "$OUT" || fail "measure.sh failed on review-body fixture"
n="$(jget "$OUT" "len(d['unclassified'])")"
hits="$(jget "$OUT" "d['unclassified_hits']")"
[[ "$n" == "1" && "$hits" == "1" ]] \
  && ok "measure: an unexplained signal in a REVIEW body is tallied like a comment" \
  || fail "measure: review body not counted, got $n entries / $hits hits"
notes="$(jget "$OUT" "' '.join(d['notes'])")"
case "$notes" in
  *"comment(s)/review(s)"*) ok "measure: the note names reviews, not comments alone" ;;
  *) fail "measure: note still labels review bodies as comments: $notes" ;;
esac

# ---------------------------------------------------------------------------
# measure.sh — multi-page gh output (Greptile P1 on PR #1206)
# ---------------------------------------------------------------------------
# `gh api --paginate` documents its output as "Each page is a separate JSON
# array or object", so a PR with >100 comments can yield `[...][...]`, which a
# bare json.loads rejects — aborting the audit on exactly the busy repos it is
# most useful for. Some gh versions merge instead, so the parser must take both.
# Exercised directly against the helper, since --fixture bypasses the gh path.
PAGINATED_PROBE=$(python3 - "$MEASURE" <<'PY'
import re, sys, json
src = open(sys.argv[1]).read()
start = src.index("def load_gh_json(")
end = src.index("def run_gh(")
ns = {"json": json}
exec(src[start:end], ns)
load = ns["load_gh_json"]
single = json.dumps([{"a": 1}, {"a": 2}])
concat = json.dumps([{"a": 1}]) + json.dumps([{"a": 2}])
spaced = json.dumps([{"a": 1}]) + "\n" + json.dumps([{"a": 2}])
results = [
    ("single", load(single) == [{"a": 1}, {"a": 2}]),
    ("concatenated", load(concat) == [{"a": 1}, {"a": 2}]),
    ("newline-separated", load(spaced) == [{"a": 1}, {"a": 2}]),
    ("empty", load("") == []),
    ("malformed-returns-None", load("{not json") is None),
]
print(";".join("%s=%s" % (n, "ok" if r else "BAD") for n, r in results))
PY
)
case "$PAGINATED_PROBE" in
  *BAD*) fail "measure: load_gh_json mishandled a page shape: $PAGINATED_PROBE" ;;
  *) ok "measure: gh page output parses as single, concatenated, or newline-separated arrays" ;;
esac

# ---------------------------------------------------------------------------
# measure.sh — fail-closed
# ---------------------------------------------------------------------------

printf 'not json at all' > "$TMP_DIR/bad.json"
"$MEASURE" --fixture "$TMP_DIR/bad.json" --json >/dev/null 2>&1
[[ $? -eq 1 ]] && ok "measure: unparseable fixture exits 1, emitting nothing" \
  || fail "measure: unparseable fixture should exit 1"

printf '{"prs": "not-an-array"}' > "$TMP_DIR/shape.json"
"$MEASURE" --fixture "$TMP_DIR/shape.json" --json >/dev/null 2>&1
[[ $? -eq 1 ]] && ok "measure: wrong-shaped fixture exits 1" \
  || fail "measure: wrong-shaped fixture should exit 1"

"$MEASURE" --fixture "$TMP_DIR/caps.json" --since 2026-01-01 --days 5 >/dev/null 2>&1
[[ $? -eq 2 ]] && ok "measure: --since and --days together is a usage error" \
  || fail "measure: mutually-exclusive window flags should exit 2"

"$MEASURE" --fixture "$TMP_DIR/caps.json" --limit 0 >/dev/null 2>&1
[[ $? -eq 2 ]] && ok "measure: --limit 0 is a usage error, not an opaque gh failure" \
  || fail "measure: --limit 0 should exit 2"

# The DEDUPED entry count is what a human weighs when deciding whether the
# phrase table needs a new entry, and it reads as noise whether the phrase
# appeared once or thirty times. The raw hit count must be reported too.
F="$TMP_DIR/unclass-freq.json"
fixture_write "$F" '[
 {"number":1,"merged_at":"2026-08-01T00:00:00Z","reviews":[],"pr_comments":[],
  "issue_comments":[{"user":"codeant-ai[bot]","body":"your quota for this org has been adjusted"}]},
 {"number":2,"merged_at":"2026-08-02T00:00:00Z","reviews":[],"pr_comments":[],
  "issue_comments":[{"user":"codeant-ai[bot]","body":"your quota for this org has been adjusted"}]},
 {"number":3,"merged_at":"2026-08-03T00:00:00Z","reviews":[],"pr_comments":[],
  "issue_comments":[{"user":"codeant-ai[bot]","body":"your quota for this org has been adjusted"}]}]'
OUT="$TMP_DIR/unclass-freq.out.json"
"$MEASURE" --fixture "$F" --json > "$OUT" || fail "measure.sh failed on frequency fixture"
entries="$(jget "$OUT" "len(d['unclassified'])")"
hits="$(jget "$OUT" "d['unclassified_hits']")"
[[ "$entries" == "1" && "$hits" == "3" ]] \
  && ok "measure: one deduped entry reports its true 3-comment frequency" \
  || fail "measure: expected 1 entry / 3 hits, got $entries / $hits"
notes="$(jget "$OUT" "' '.join(d['notes'])")"
case "$notes" in
  *"across 3 limit-shaped comment(s)/review(s)"*) ok "measure: the note states the body count, not just distinct pairs" ;;
  *) fail "measure: note understates frequency: $notes" ;;
esac

# ---------------------------------------------------------------------------
# drift.sh — Test Plan item 1: a matching snapshot files nothing
# ---------------------------------------------------------------------------

BASE="$TMP_DIR/baseline.json"
cat > "$BASE" <<'JSON'
{"schema":"review-stack-baseline/v1",
 "source":{"issue":1199,"record":"test","as_of":"2026-06-27"},
 "tools":[
  {"key":"coderabbit","role":"primary","billed":"paid","gates_merge":false,"approves_via":"none","expected_caps":[]},
  {"key":"codeant","role":"approver","billed":"trial","gates_merge":true,"approves_via":"review","expected_caps":["not_subscribed"]},
  {"key":"bugbot","role":"fallback","billed":"paid","gates_merge":true,"approves_via":"check_run","expected_caps":[]},
  {"key":"greptile","role":"dormant","billed":"cancelled","gates_merge":false,"approves_via":"none","expected_caps":[]},
  {"key":"graphite","role":"advisory","billed":"free","gates_merge":false,"approves_via":"none","expected_caps":[]},
  {"key":"vercel","role":"off","billed":"free","gates_merge":false,"approves_via":"none","expected_caps":[]}]}
JSON

# A snapshot that agrees with the baseline on every axis: CodeAnt approves and
# its only cap is the expected one; nothing else is capped or silently paid.
SNAP_CLEAN="$TMP_DIR/snap-clean.json"
cat > "$SNAP_CLEAN" <<'JSON'
{"generated_at":"2026-08-21T00:00:00Z","repo":"test/repo","source":"fixture",
 "window":{"since":"2026-07-22","until":"2026-08-21","days":30,"pr_count":10,"limit":60,"truncated":false},
 "tools":[
  {"key":"coderabbit","name":"CodeRabbit","observed_state":"active","plan_observed":"pro","prs_touched":10,"review_objects":10,"approved":0,"changes_requested":0,"inline_findings":40,"issue_comments":10,"sole_provider_on":3,"cap_signals":[],"cap_kinds":[]},
  {"key":"codeant","name":"CodeAnt","observed_state":"capped","plan_observed":null,"prs_touched":10,"review_objects":20,"approved":15,"changes_requested":0,"inline_findings":10,"issue_comments":30,"sole_provider_on":2,"cap_signals":[{"pr":1,"kind":"not_subscribed","pattern":"x"}],"cap_kinds":["not_subscribed"]},
  {"key":"bugbot","name":"BugBot (Cursor)","observed_state":"active","plan_observed":null,"prs_touched":8,"review_objects":8,"approved":0,"changes_requested":0,"inline_findings":12,"issue_comments":0,"sole_provider_on":1,"cap_signals":[],"cap_kinds":[]},
  {"key":"greptile","name":"Greptile","observed_state":"silent","plan_observed":null,"prs_touched":0,"review_objects":0,"approved":0,"changes_requested":0,"inline_findings":0,"issue_comments":0,"sole_provider_on":0,"cap_signals":[],"cap_kinds":[]},
  {"key":"graphite","name":"Graphite","observed_state":"active","plan_observed":null,"prs_touched":4,"review_objects":4,"approved":0,"changes_requested":0,"inline_findings":4,"issue_comments":0,"sole_provider_on":0,"cap_signals":[],"cap_kinds":[]},
  {"key":"vercel","name":"Vercel Agent","observed_state":"silent","plan_observed":null,"prs_touched":0,"review_objects":0,"approved":0,"changes_requested":0,"inline_findings":0,"issue_comments":0,"sole_provider_on":0,"cap_signals":[],"cap_kinds":[]}],
 "unclassified":[],"notes":[]}
JSON

OUT="$TMP_DIR/drift-clean.json"
"$DRIFT" --snapshot "$SNAP_CLEAN" --baseline "$BASE" --json > "$OUT" 2>/dev/null
rc=$?
[[ $rc -eq 0 ]] && ok "drift: no-drift snapshot exits 0 (Test Plan 1)" \
  || fail "drift: no-drift snapshot should exit 0, got $rc"
n="$(jget "$OUT" "d['drift_count']")"
[[ "$n" == "0" ]] && ok "drift: no-drift snapshot reports drift_count 0" \
  || fail "drift: expected drift_count 0, got $n"

# The clean case must stay clean for the RIGHT reason: BugBot gates the merge
# and posts zero APPROVED reviews, and that must not be read as a missing
# approval. This is the false positive the approves_via split exists to prevent.
codes="$(jget "$OUT" "[x['code'] for x in d['drift']]")"
[[ "$codes" == "[]" ]] && ok "drift: check-run approver (BugBot) produces no false D4" \
  || fail "drift: unexpected findings on the clean snapshot: $codes"

# ---------------------------------------------------------------------------
# drift.sh — Test Plan item 2: one drift finding, naming tool and divergence
# ---------------------------------------------------------------------------

# Premise built by mutating ONLY the axis under test: BugBot flips to capped
# with a kind the baseline does not list. Everything else stays as the clean
# snapshot, so exactly one finding can be attributed to this change.
SNAP_DRIFT="$TMP_DIR/snap-drift.json"
python3 - "$SNAP_CLEAN" "$SNAP_DRIFT" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
for t in d["tools"]:
    if t["key"] == "bugbot":
        t["observed_state"] = "capped"
        t["cap_kinds"] = ["spend_limit"]
        t["cap_signals"] = [{"pr": 4, "kind": "spend_limit", "pattern": "hit a usage or spend limit"}]
json.dump(d, open(sys.argv[2], "w"), indent=2)
PY

OUT="$TMP_DIR/drift-one.json"
"$DRIFT" --snapshot "$SNAP_DRIFT" --baseline "$BASE" --json > "$OUT" 2>/dev/null
rc=$?
[[ $rc -eq 3 ]] && ok "drift: drifted snapshot exits 3 (analysis fine, answer is bad news)" \
  || fail "drift: drifted snapshot should exit 3, got $rc"
n="$(jget "$OUT" "d['drift_count']")"
[[ "$n" == "1" ]] && ok "drift: simulated cap produces exactly one finding (Test Plan 2)" \
  || fail "drift: expected exactly 1 finding, got $n"
code="$(jget "$OUT" "d['drift'][0]['code']")"
tool="$(jget "$OUT" "d['drift'][0]['tool']")"
sev="$(jget "$OUT" "d['drift'][0]['severity']")"
[[ "$code" == "D3" && "$tool" == "bugbot" ]] \
  && ok "drift: finding names the tool and the divergence (D3/bugbot)" \
  || fail "drift: expected D3/bugbot, got $code/$tool"
[[ "$sev" == "high" ]] && ok "drift: cap on a merge-gating tool is high severity" \
  || fail "drift: expected high severity for a gating tool, got $sev"

# ---------------------------------------------------------------------------
# drift.sh — Test Plan item 3: a second run dedupes on a stable marker
# ---------------------------------------------------------------------------

OUT2="$TMP_DIR/drift-two.json"
"$DRIFT" --snapshot "$SNAP_DRIFT" --baseline "$BASE" --json > "$OUT2" 2>/dev/null
m1="$(jget "$OUT" "d['drift'][0]['marker']")"
m2="$(jget "$OUT2" "d['drift'][0]['marker']")"
[[ "$m1" == "$m2" ]] && ok "drift: marker is byte-identical across runs (Test Plan 3)" \
  || fail "drift: marker changed between runs: '$m1' vs '$m2'"
[[ "$m1" == "<!-- review-stack-audit: bugbot/D3 -->" ]] \
  && ok "drift: marker keys on (tool, code) only" \
  || fail "drift: unexpected marker shape: '$m1'"

# A marker must survive a changed window — the dedup key cannot embed anything
# that moves month to month, or every month files a duplicate.
SNAP_LATER="$TMP_DIR/snap-later.json"
python3 - "$SNAP_DRIFT" "$SNAP_LATER" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d["window"]["since"] = "2026-08-22"
d["window"]["until"] = "2026-09-21"
d["generated_at"] = "2026-09-21T00:00:00Z"
json.dump(d, open(sys.argv[2], "w"), indent=2)
PY
OUT3="$TMP_DIR/drift-three.json"
"$DRIFT" --snapshot "$SNAP_LATER" --baseline "$BASE" --json > "$OUT3" 2>/dev/null
m3="$(jget "$OUT3" "d['drift'][0]['marker']")"
[[ "$m1" == "$m3" ]] && ok "drift: marker is stable across a moved window" \
  || fail "drift: marker moved with the window: '$m1' vs '$m3'"

# D2 on a truncated sample is a false positive with real consequences: "silent"
# there means "absent from the PRs we happened to sample", and the finding tells
# a human to go cancel a subscription. Greptile P1 on PR #1206.
TRUNC_BASE="$TMP_DIR/baseline-d2trunc.json"
python3 - "$BASE" "$TRUNC_BASE" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
for t in d["tools"]:
    if t["key"] == "greptile":
        t["billed"] = "paid"     # premise: a PAID tool, so D2 is eligible at all
json.dump(d, open(sys.argv[2], "w"), indent=2)
PY
# Control: the identical snapshot WITHOUT truncation must fire D2, or the case
# below would pass for the wrong reason (nothing to suppress).
OUT="$TMP_DIR/d2-control.json"
"$DRIFT" --snapshot "$SNAP_CLEAN" --baseline "$TRUNC_BASE" --json > "$OUT" 2>/dev/null
control="$(jget "$OUT" "sorted(x['code'] for x in d['drift'])")"
[[ "$control" == *"D2"* ]] || fail "drift: D2-truncation control did not fire D2 on a full window: $control"

SNAP="$TMP_DIR/snap-d2-trunc.json"
python3 - "$SNAP_CLEAN" "$SNAP" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d["window"]["truncated"] = True          # the ONLY change from the control above
json.dump(d, open(sys.argv[2], "w"), indent=2)
PY
OUT="$TMP_DIR/d2-trunc.json"
"$DRIFT" --snapshot "$SNAP" --baseline "$TRUNC_BASE" --json > "$OUT" 2>/dev/null
codes="$(jget "$OUT" "sorted(x['code'] for x in d['drift'])")"
[[ "$codes" != *"D2"* ]] \
  && ok "drift: D2 is not evaluated on a truncated sample (no cancel-the-subscription false positive)" \
  || fail "drift: D2 fired on a truncated window: $codes"
notes="$(jget "$OUT" "' '.join(d['notes'])")"
case "$notes" in
  *"D2 was suppressed"*) ok "drift: the suppressed D2 is named, not silently dropped" ;;
  *) fail "drift: D2 suppression was silent: $notes" ;;
esac
case "$notes" in
  *"silence is silence"*) fail "drift: the stale claim that D2 survives truncation is still present" ;;
  *) ok "drift: truncation note no longer claims D2 stays reliable" ;;
esac

# ---------------------------------------------------------------------------
# drift.sh — remaining codes
# ---------------------------------------------------------------------------

# D1: a demoted tool that was nonetheless the only finder on a PR.
SNAP="$TMP_DIR/snap-d1.json"
python3 - "$SNAP_CLEAN" "$SNAP" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
for t in d["tools"]:
    if t["key"] == "greptile":
        t.update({"observed_state": "active", "prs_touched": 3,
                  "inline_findings": 9, "sole_provider_on": 2})
json.dump(d, open(sys.argv[2], "w"), indent=2)
PY
OUT="$TMP_DIR/d1.json"; "$DRIFT" --snapshot "$SNAP" --baseline "$BASE" --json > "$OUT" 2>/dev/null
codes="$(jget "$OUT" "sorted(x['code']+'/'+x['tool'] for x in d['drift'])")"
[[ "$codes" == "['D1/greptile']" ]] && ok "drift: D1 fires for a demoted tool being leaned on" \
  || fail "drift: expected only D1/greptile, got $codes"

# D2: a paid tool that did nothing. The baseline above has greptile cancelled,
# so this case must set it paid itself rather than assume.
BASE_PAID="$TMP_DIR/baseline-paid.json"
python3 - "$BASE" "$BASE_PAID" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
for t in d["tools"]:
    if t["key"] == "greptile":
        t["billed"] = "paid"
json.dump(d, open(sys.argv[2], "w"), indent=2)
PY
OUT="$TMP_DIR/d2.json"; "$DRIFT" --snapshot "$SNAP_CLEAN" --baseline "$BASE_PAID" --json > "$OUT" 2>/dev/null
codes="$(jget "$OUT" "sorted(x['code']+'/'+x['tool'] for x in d['drift'])")"
[[ "$codes" == "['D2/greptile']" ]] && ok "drift: D2 fires for a paid tool that went silent" \
  || fail "drift: expected only D2/greptile, got $codes"
sev="$(jget "$OUT" "d['drift'][0]['severity']")"
[[ "$sev" == "high" ]] && ok "drift: paying for silence is high severity" \
  || fail "drift: D2 should be high severity, got $sev"

# D4: the recorded review-approver stops approving.
SNAP="$TMP_DIR/snap-d4.json"
python3 - "$SNAP_CLEAN" "$SNAP" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
for t in d["tools"]:
    if t["key"] == "codeant":
        t["approved"] = 0
json.dump(d, open(sys.argv[2], "w"), indent=2)
PY
OUT="$TMP_DIR/d4.json"; "$DRIFT" --snapshot "$SNAP" --baseline "$BASE" --json > "$OUT" 2>/dev/null
codes="$(jget "$OUT" "sorted(x['code']+'/'+x['tool'] for x in d['drift'])")"
[[ "$codes" == "['D4/codeant']" ]] && ok "drift: D4 fires when the review-approver stops approving" \
  || fail "drift: expected only D4/codeant, got $codes"

# D5: a tool reviewing that the baseline never decided on.
BASE_SHORT="$TMP_DIR/baseline-short.json"
python3 - "$BASE" "$BASE_SHORT" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d["tools"] = [t for t in d["tools"] if t["key"] != "graphite"]
json.dump(d, open(sys.argv[2], "w"), indent=2)
PY
OUT="$TMP_DIR/d5.json"; "$DRIFT" --snapshot "$SNAP_CLEAN" --baseline "$BASE_SHORT" --json > "$OUT" 2>/dev/null
codes="$(jget "$OUT" "sorted(x['code']+'/'+x['tool'] for x in d['drift'])")"
[[ "$codes" == "['D5/graphite']" ]] && ok "drift: D5 fires for a reviewing tool absent from the baseline" \
  || fail "drift: expected only D5/graphite, got $codes"

# ---------------------------------------------------------------------------
# drift.sh — refuses to answer what it cannot check
# ---------------------------------------------------------------------------

BAD="$TMP_DIR/baseline-badschema.json"
printf '{"schema":"something-else","tools":[]}' > "$BAD"
"$DRIFT" --snapshot "$SNAP_CLEAN" --baseline "$BAD" --json >/dev/null 2>&1
[[ $? -eq 1 ]] && ok "drift: unknown baseline schema exits 1 rather than reporting 'no drift'" \
  || fail "drift: unknown schema must exit 1, never a clean result"

printf 'nope' > "$TMP_DIR/garbage.json"
"$DRIFT" --snapshot "$TMP_DIR/garbage.json" --baseline "$BASE" --json >/dev/null 2>&1
[[ $? -eq 1 ]] && ok "drift: unparseable snapshot exits 1" \
  || fail "drift: unparseable snapshot must exit 1"

# The worst possible output from this tool is a confident "no drift" produced by
# a comparison that never happened. An empty tools array walks straight past the
# loop and exits 0 unless it is refused explicitly.
printf '{"window":{},"tools":[],"unclassified":[]}' > "$TMP_DIR/snap-empty.json"
"$DRIFT" --snapshot "$TMP_DIR/snap-empty.json" --baseline "$BASE" --json >/dev/null 2>&1
[[ $? -eq 1 ]] && ok "drift: an empty snapshot is refused, never reported as 'no drift'" \
  || fail "drift: empty tools array must exit 1, not 0"

# But a snapshot full of tools the baseline never heard of is NOT a failed
# comparison — it is a pile of D5 findings, and suppressing them would be the
# opposite error.
printf '{"schema":"review-stack-baseline/v1","source":{},"tools":[]}' > "$TMP_DIR/baseline-empty.json"
OUT="$TMP_DIR/all-d5.json"
"$DRIFT" --snapshot "$SNAP_CLEAN" --baseline "$TMP_DIR/baseline-empty.json" --json > "$OUT" 2>/dev/null
rc=$?
n="$(jget "$OUT" "d['drift_count']")"
[[ $rc -eq 3 && "$n" -gt 0 ]] \
  && ok "drift: an empty baseline yields D5 findings rather than a false clean pass" \
  || fail "drift: empty baseline should report D5s (rc=$rc, count=$n)"

# D4 is the check that catches the merge gate's approver going quiet. A baseline
# entry with no approves_via gets one inferred, and for every role but
# "approver" that inference turns D4 off. That must not happen invisibly.
BASE_INFER="$TMP_DIR/baseline-infer.json"
python3 - "$BASE" "$BASE_INFER" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
for t in d["tools"]:
    if t["key"] == "coderabbit":
        t.pop("approves_via", None)
json.dump(d, open(sys.argv[2], "w"), indent=2)
PY
OUT="$TMP_DIR/infer.json"
"$DRIFT" --snapshot "$SNAP_CLEAN" --baseline "$BASE_INFER" --json > "$OUT" 2>/dev/null
notes="$(jget "$OUT" "' '.join(d['notes'])")"
case "$notes" in
  *approves_via*) ok "drift: an inferred approves_via that disables D4 is surfaced" ;;
  *) fail "drift: silently inferred approves_via produced no note: $notes" ;;
esac

# The inference must NOT read role "primary" as approving via review: CodeRabbit
# is primary and measured 0 approvals, so that would fire D4 against it forever.
codes="$(jget "$OUT" "sorted(x['code']+'/'+x['tool'] for x in d['drift'])")"
[[ "$codes" == "[]" ]] \
  && ok "drift: role 'primary' is not inferred as a review-approver (no permanent false D4)" \
  || fail "drift: inferring approves_via for a primary role produced findings: $codes"

"$DRIFT" --snapshot "$SNAP_CLEAN" >/dev/null 2>&1
[[ $? -eq 2 ]] && ok "drift: missing --baseline is a usage error" \
  || fail "drift: missing --baseline should exit 2"

# Truncation and unclassified entries must reach the caller as caveats, because
# both mean "absence of a finding is not proof of absence".
SNAP="$TMP_DIR/snap-trunc.json"
python3 - "$SNAP_CLEAN" "$SNAP" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d["window"]["truncated"] = True
d["unclassified"] = [{"tool": "coderabbit", "pr": 9, "token": "quota", "excerpt": "..."}]
json.dump(d, open(sys.argv[2], "w"), indent=2)
PY
OUT="$TMP_DIR/trunc.json"; "$DRIFT" --snapshot "$SNAP" --baseline "$BASE" --json > "$OUT" 2>/dev/null
notes="$(jget "$OUT" "' '.join(d['notes'])")"
case "$notes" in
  *truncated*|*floors*) ok "drift: truncation is surfaced as a caveat" ;;
  *) fail "drift: truncated snapshot produced no caveat: $notes" ;;
esac
case "$notes" in
  *unclassified*) ok "drift: unclassified cap candidates are surfaced as a caveat" ;;
  *) fail "drift: unclassified entries produced no caveat: $notes" ;;
esac

# ---------------------------------------------------------------------------
# report-path.sh — a second audit in one month must never overwrite the first
#
# The bug this pins (issue #1345): Step 7 derived the report path from the
# calendar month alone, so two audits in one month resolved to the SAME file and
# the second silently destroyed the first. It happened for real in 2026-08 and
# PR #1338 had to rename its report by hand. Every case below is offline and
# builds its own directory, so none can pass because of another's leftovers.
# ---------------------------------------------------------------------------

RP_DIR="$TMP_DIR/report-path"
mkdir -p "$RP_DIR"

# rp_run <dir> <month> [extra args...] — echoes the path, returns the exit code.
rp_run() { "$REPORT_PATH" --dir "$1" --month "$2" "${@:3}"; }

# Case 1 — an empty directory yields the unsuffixed canonical name. The first
# report of a month must read exactly as it always has; a fix that renamed every
# report would be a different (and worse) change.
D="$RP_DIR/empty"; mkdir -p "$D"
got="$(rp_run "$D" 2026-08)" \
  && [[ "$got" == "$D/review-stack-audit-2026-08.md" ]] \
  && ok "report-path: a free month returns the canonical unsuffixed name — the common case is unchanged" \
  || fail "report-path: empty dir should return $D/review-stack-audit-2026-08.md, got '$got'"

# Case 2 — the base name taken yields a DISTINCT path. This is the collision the
# issue reports; before the fix both runs returned the same string.
D="$RP_DIR/collide"; mkdir -p "$D"
base="$D/review-stack-audit-2026-08.md"
printf 'first audit\n' > "$base"
second="$(rp_run "$D" 2026-08)"
[[ -n "$second" && "$second" != "$base" ]] \
  && ok "report-path: a second same-month audit gets a distinct path — the month-mate is not overwritten" \
  || fail "report-path: second run returned '$second', which must differ from '$base'"
[[ "$second" == "$D/review-stack-audit-2026-08-2.md" ]] \
  && ok "report-path: the first collision suffix is -2 — a stable, predictable series" \
  || fail "report-path: expected the -2 suffix, got '$second'"

# Case 3 — base AND -2 taken yields a third distinct path, so the counter walks
# rather than parking on the first suffix (which would collide from run three on).
printf 'second audit\n' > "$second"
third="$(rp_run "$D" 2026-08)"
[[ "$third" == "$D/review-stack-audit-2026-08-3.md" ]] \
  && ok "report-path: the counter advances past every taken name — run three lands on -3" \
  || fail "report-path: expected the -3 suffix, got '$third'"

# The acceptance criterion in one assertion: over a run of audits, EVERY path
# handed back is free at the moment it is handed back, and every report survives.
D="$RP_DIR/sequence"; mkdir -p "$D"
collided=""
for i in 1 2 3 4 5; do
  p="$(rp_run "$D" 2026-08)" || { fail "report-path: run $i exited non-zero"; break; }
  if [[ -e "$p" || -L "$p" ]]; then collided="$p"; fi
  printf 'audit %s\n' "$i" > "$p"
done
[[ -z "$collided" ]] \
  && ok "report-path: five same-month audits never target an existing name — nothing is overwritten" \
  || fail "report-path: returned an already-occupied path: $collided"
n="$(ls -1 "$D" | wc -l | tr -d ' ')"
[[ "$n" == "5" ]] \
  && ok "report-path: all five same-month reports survive on disk (the #1345 acceptance criterion)" \
  || fail "report-path: expected 5 surviving reports, found $n"

# A DIRECTORY or a DANGLING SYMLINK occupies the name just as a file does: `mv`
# onto either loses the report. A plain `-f` test would call both slots free.
D="$RP_DIR/nonfile"; mkdir -p "$D"
mkdir "$D/review-stack-audit-2026-09.md"
got="$(rp_run "$D" 2026-09)"
[[ "$got" != "$D/review-stack-audit-2026-09.md" ]] \
  && ok "report-path: a directory occupying the name counts as taken — mv onto it would not produce a report" \
  || fail "report-path: a directory at the base name was treated as free"
ln -s "$D/no-such-target" "$D/review-stack-audit-2026-10.md"
got="$(rp_run "$D" 2026-10)"
[[ "$got" != "$D/review-stack-audit-2026-10.md" ]] \
  && ok "report-path: a dangling symlink counts as taken — -e alone reads it as absent" \
  || fail "report-path: a dangling symlink at the base name was treated as free"

# It is a PURE function: the caller writes, never the script. A script that
# created its own placeholder would make the audit's advisory-only contract false.
D="$RP_DIR/pure"; mkdir -p "$D"
before="$(ls -A "$D" | sort)"
rp_run "$D" 2026-08 >/dev/null
rp_run "$D" 2026-08 >/dev/null
after="$(ls -A "$D" | sort)"
[[ "$before" == "$after" ]] \
  && ok "report-path: resolving a path writes nothing — the skill stays advisory-only" \
  || fail "report-path: the script mutated its target directory"

# --series keeps the manual ai-review-tool-audit-* series reachable without a
# second copy of the suffix logic living somewhere else.
D="$RP_DIR/series"; mkdir -p "$D"
got="$(rp_run "$D" 2026-08 --series ai-review-tool-audit)"
[[ "$got" == "$D/ai-review-tool-audit-2026-08.md" ]] \
  && ok "report-path: --series honoured, so a second series needs no second implementation" \
  || fail "report-path: --series override returned '$got'"

# Bad input is refused loudly. A malformed month would silently produce a name
# outside the series, so later runs would not recognise it as a month-mate — it
# would stop colliding by being unfindable rather than by being distinct.
months_ok=yes
for bad in 2026-13 2026-00 26-08 2026-8 "" ; do
  "$REPORT_PATH" --dir "$RP_DIR" --month "$bad" >/dev/null 2>&1
  if [[ $? -ne 2 ]]; then
    fail "report-path: month '$bad' must be a usage error (exit 2)"
    months_ok=no
  fi
done
[[ "$months_ok" == "yes" ]] \
  && ok "report-path: malformed months are usage errors, never a silently off-series name" \
  || true

"$REPORT_PATH" --month 2026-08 >/dev/null 2>&1
[[ $? -eq 2 ]] && ok "report-path: missing --dir is a usage error" \
  || fail "report-path: missing --dir should exit 2"
"$REPORT_PATH" --dir "$RP_DIR" >/dev/null 2>&1
[[ $? -eq 2 ]] && ok "report-path: missing --month is a usage error" \
  || fail "report-path: missing --month should exit 2"
"$REPORT_PATH" --dir "$RP_DIR" --month 2026-08 --series ../escape >/dev/null 2>&1
[[ $? -eq 2 ]] && ok "report-path: a --series with path separators is refused — the report cannot land outside --dir" \
  || fail "report-path: --series ../escape should exit 2"

# The failure this script exists to prevent, in its subtlest form: a directory it
# cannot read cannot prove a name is free. Returning the base name there would
# launder "I could not check" into "no collision" — the exact
# guards-that-pass-by-not-running shape. It must refuse, and print NO path, so a
# caller doing `REPORT=$(...)` gets an empty string rather than a live target.
"$REPORT_PATH" --dir "$RP_DIR/definitely-not-here" --month 2026-08 >/dev/null 2>&1
[[ $? -eq 1 ]] && ok "report-path: a missing target directory is refused, never assumed empty" \
  || fail "report-path: a missing --dir should exit 1"

D="$RP_DIR/locked"; mkdir -p "$D"
printf 'prior audit\n' > "$D/review-stack-audit-2026-08.md"
chmod 000 "$D"
out="$("$REPORT_PATH" --dir "$D" --month 2026-08 2>/dev/null)"; rc=$?
chmod 755 "$D"
if [[ $rc -eq 0 ]] && [[ "$(id -u)" == "0" ]]; then
  # root ignores the permission bits, so this case cannot be staged there.
  ok "report-path: unreadable-directory case skipped as root (chmod 000 is not enforced for uid 0)"
else
  [[ $rc -eq 1 && -z "$out" ]] \
    && ok "report-path: an unreadable directory refuses and prints no path — 'cannot check' never becomes 'no collision'" \
    || fail "report-path: unreadable dir should exit 1 with empty stdout (rc=$rc, out='$out')"
fi

# ---------------------------------------------------------------------------
# The Step 7 reservation — resolve, then CLAIM with O_EXCL
#
# report-path.sh creates nothing, so its answer is only true at the instant it
# is given (CodeAnt Critical + CodeRabbit major on PR #1511). Step 7 closes that
# window by reserving the returned path with `set -o noclobber`. These cases pin
# the contract that fix depends on: the reservation is atomic, and a reserved
# path is subsequently seen as taken by the resolver.
# ---------------------------------------------------------------------------

D="$RP_DIR/reserve"; mkdir -p "$D"

# Interleave two audits the way concurrency would: A resolves and reserves, then
# B resolves. B must be handed a different name — the reservation, not luck, is
# what makes A's path safe to write.
a_path="$(rp_run "$D" 2026-08)"
( set -o noclobber; : > "$a_path" ) 2>/dev/null \
  && ok "report-path: a freshly resolved path can be reserved with O_EXCL — the claim succeeds on the happy path" \
  || fail "report-path: could not reserve freshly resolved path $a_path"
b_path="$(rp_run "$D" 2026-08)"
[[ "$b_path" != "$a_path" ]] \
  && ok "report-path: a path reserved by O_EXCL is seen as taken by the next run — interleaved audits cannot share a name" \
  || fail "report-path: second run returned the reserved path '$a_path' again"

# The reservation must REFUSE rather than truncate, otherwise it would itself be
# the overwrite #1345 is about. Re-reserving A's path has to fail with the file's
# contents intact.
printf 'audit A body\n' > "$a_path"
( set -o noclobber; : > "$a_path" ) 2>/dev/null \
  && fail "report-path: O_EXCL reservation overwrote an existing report — the guard is inert" \
  || ok "report-path: reserving an already-claimed path fails instead of truncating it"
[[ "$(cat "$a_path")" == "audit A body" ]] \
  && ok "report-path: the refused reservation left the prior report byte-for-byte intact" \
  || fail "report-path: prior report was damaged by a refused reservation"

# A dangling symlink occupies a name for the resolver (`-e || -L`); the
# reservation must agree, or the two layers would disagree about what is free.
ln -s "$D/nonexistent-target" "$D/review-stack-audit-2026-09.md"
( set -o noclobber; : > "$D/review-stack-audit-2026-09.md" ) 2>/dev/null \
  && fail "report-path: O_EXCL wrote through a dangling symlink the resolver treats as taken" \
  || ok "report-path: O_EXCL and the resolver agree that a dangling symlink is an occupied name"

# ---------------------------------------------------------------------------
# The whole Step 7 recipe — claim, retry, and clean up
#
# The claim introduced two failure modes of its own, both caught in review on
# PR #1511: a lost race must not discard the audit (CodeAnt Major), and a failed
# compose must not park an empty file on the canonical name (Bugbot Medium).
# step7_claim mirrors the documented block exactly so those are pinned behaviour,
# not just prose. `mode=fail` aborts after claiming, standing in for a compose
# that dies before `mv`.
# ---------------------------------------------------------------------------

step7_claim() {
  bash -c '
    set -u
    REPORT_PATH="$1"; REPORT_DIR="$2"; MONTH="$3"; MODE="$4"
    REPORT=""
    for _attempt in 1 2 3 4 5; do
      CANDIDATE="$("$REPORT_PATH" --dir "$REPORT_DIR" --month "$MONTH")" || exit 1
      if ( set -o noclobber; : > "$CANDIDATE" ) 2>/dev/null; then REPORT="$CANDIDATE"; break; fi
    done
    [[ -n "$REPORT" ]] || exit 1
    TMP_REPORT="$REPORT_DIR/.$(basename "$REPORT").tmp"
    cleanup_report() { rm -f "$TMP_REPORT"; [[ -s "$REPORT" ]] || rm -f "$REPORT"; }
    trap cleanup_report EXIT
    printf "%s\n" "$REPORT"
    [[ "$MODE" == "fail" ]] && exit 9
    printf "report body\n" > "$TMP_REPORT"
    mv "$TMP_REPORT" "$REPORT"
  ' _ "${4:-$REPORT_PATH}" "$1" "$2" "$3"
}

# A resolver that loses the race exactly once: it creates the very path it
# returns, but only on its first call. That is the window between resolving and
# claiming — the only thing the retry loop exists for. A merely pre-existing file
# cannot exercise it, because report-path.sh would skip that name up front.
RACER="$TMP_DIR/racing-report-path.sh"
cat > "$RACER" <<EOF
#!/usr/bin/env bash
set -euo pipefail
P="\$("$REPORT_PATH" "\$@")"
if [[ ! -e "$TMP_DIR/racer-fired" ]]; then
  : > "$TMP_DIR/racer-fired"
  : > "\$P"
fi
printf '%s\n' "\$P"
EOF
chmod +x "$RACER"

D="$RP_DIR/step7"; mkdir -p "$D"

# Happy path: the claimed name is the canonical one and survives with content.
got="$(step7_claim "$D" 2026-08 ok)"
[[ "$got" == "$D/review-stack-audit-2026-08.md" && -s "$got" ]] \
  && ok "step7: a successful run keeps its claimed report, non-empty, at the canonical name" \
  || fail "step7: expected a non-empty canonical report, got '$got'"

# Lost race, injected in the real window: the first resolve is stolen out from
# under the claim. The run must retry onto the next suffix, NOT abort — aborting
# would throw away a completed measurement run over a moment's contention.
D2="$RP_DIR/step7-race"; mkdir -p "$D2"
got="$(step7_claim "$D2" 2026-08 ok "$RACER")"; rc=$?
[[ $rc -eq 0 && "$got" == "$D2/review-stack-audit-2026-08-2.md" && -s "$got" ]] \
  && ok "step7: a claim stolen mid-window is retried onto the next suffix, not discarded" \
  || fail "step7: race path returned rc=$rc path='$got' (expected the -2 suffix, written)"
[[ -e "$D2/review-stack-audit-2026-08.md" ]] \
  && ok "step7: the winner's claim is left untouched by the audit that lost the race" \
  || fail "step7: the losing run removed the winner's claimed file"

# Failed compose: the claim is a zero-byte placeholder, so the trap must remove
# it. Otherwise the canonical name stays occupied by a blank file and every later
# audit that month is pushed onto a suffix — the confusion #1345 is about.
D3="$RP_DIR/step7-crash"; mkdir -p "$D3"
got="$(step7_claim "$D3" 2026-08 fail)"; rc=$?
[[ $rc -eq 9 ]] \
  && ok "step7: a compose failure propagates its exit status" \
  || fail "step7: expected rc=9 from the failing compose, got $rc"
[[ ! -e "$got" ]] \
  && ok "step7: a failed run removes its empty claim — the canonical name is not left occupied by a blank file" \
  || fail "step7: empty placeholder survived a failed run at $got"
[[ -z "$(ls -A "$D3")" ]] \
  && ok "step7: a failed run leaves the directory exactly as it found it (temp file included)" \
  || fail "step7: failed run left debris: $(ls -A "$D3")"

# ...and because the name was released, the next audit gets the canonical name
# back rather than being pushed onto -2 forever.
got="$(step7_claim "$D3" 2026-08 ok)"
[[ "$got" == "$D3/review-stack-audit-2026-08.md" && -s "$got" ]] \
  && ok "step7: after a failed run the canonical name is reusable — no permanent suffix drift" \
  || fail "step7: expected the canonical name to be free again, got '$got'"

# ---------------------------------------------------------------------------
# --report-to-repo must target the CURRENT worktree (Bugbot High, PR #1511)
#
# Step 7's guard admits the flag only when the current tree is NOT repo-root.sh's
# answer. Deriving the destination from $REPO_ROOT therefore contradicts the very
# condition that let the flag through: the report would land in the root
# checkout — normally on `main` — dirtying main and leaving the file out of the
# PR the flag exists to produce. A doc assertion because the destination lives in
# SKILL.md, not in a script.
# ---------------------------------------------------------------------------

SKILL_MD="$REPO_ROOT/.claude/skills/review-stack-audit/SKILL.md"
if [[ -r "$SKILL_MD" ]]; then
  grep -qF 'REPORT_DIR="$WORKTREE_ROOT/.claude/reference"' "$SKILL_MD" \
    && ok "skill: --report-to-repo derives its destination from the current worktree" \
    || fail "skill: --report-to-repo no longer targets \$WORKTREE_ROOT"
  grep -qF 'REPORT_DIR="$REPO_ROOT/.claude/reference"' "$SKILL_MD" \
    && fail "skill: --report-to-repo targets \$REPO_ROOT — the root checkout the guard excludes, so the report would dirty main and miss the PR" \
    || ok "skill: --report-to-repo never targets \$REPO_ROOT, the root checkout its own guard excludes"
else
  fail "skill: SKILL.md not readable at $SKILL_MD"
fi

# ---------------------------------------------------------------------------
# The shipped baseline must be valid against the shipped drift engine.
# ---------------------------------------------------------------------------

if [[ -r "$BASELINE_REAL" ]]; then
  "$DRIFT" --snapshot "$SNAP_CLEAN" --baseline "$BASELINE_REAL" --json >/dev/null 2>&1
  rc=$?
  [[ $rc -eq 0 || $rc -eq 3 ]] \
    && ok "baseline: the shipped review-stack-baseline.json parses and analyses cleanly" \
    || fail "baseline: shipped baseline rejected by drift.sh (rc=$rc)"
  keys="$(jget "$BASELINE_REAL" "sorted(t['key'] for t in d['tools'])")"
  # baseline may include additional off/self-hosted entries beyond the six bots measure.sh tracks;
  # check that all six bot-trackable tools are present rather than doing an exact-match
  missing="$(jget "$BASELINE_REAL" "[k for k in ['bugbot','codeant','coderabbit','graphite','greptile','vercel'] if k not in [t['key'] for t in d['tools']]]")"
  [[ "$missing" == "[]" ]] \
    && ok "baseline: covers every tool measure.sh reports on" \
    || fail "baseline: measure.sh tools missing from baseline: $missing (all keys: $keys)"
  # drift.sh builds base_by_key as a dict — duplicate keys cause last-write-wins silently;
  # validate uniqueness so a malformed baseline doesn't report false 'no drift'
  unique_count="$(jget "$BASELINE_REAL" "len(set(t['key'] for t in d['tools']))")"
  total_count="$(jget "$BASELINE_REAL" "len(d['tools'])")"
  [[ "$unique_count" == "$total_count" ]] \
    && ok "baseline: tool keys are unique (no duplicate entries)" \
    || fail "baseline: duplicate tool keys — $((total_count - unique_count)) collision(s); drift.sh silently uses last-write-wins for duplicates"
else
  fail "baseline: $BASELINE_REAL is missing"
fi

[[ $FAILED -eq 0 ]] && echo "All review-stack-audit tests passed."
exit $FAILED
