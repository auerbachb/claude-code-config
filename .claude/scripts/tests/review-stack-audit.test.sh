#!/usr/bin/env bash
# Tests for /review-stack-audit's own engines (issues #1201, #1345, #1808, #1809):
#   measure.sh — per-tool measurement and cap classification, the multi-repo
#                roll-up (--repos / --all-repos), a golden byte-identity
#                check that the single-repo shape did not move under it, and
#                the spend ledger (--ledger, review_ledger.py, the real
#                pricing matrix's review-stack-rates block)
#   drift.sh   — snapshot vs baseline comparison
# catalog: tests — Tests `/review-stack-audit`'s measurement and drift engines offline through their fixture path
#
# The third engine, report-path.sh, moved to .claude/scripts/ when /harness-audit
# turned out to need it too (#1519), and its cases moved with it to
# .claude/scripts/tests/report-path.test.sh — including the doc assertions that
# THIS skill's Step 7 still ships the claim/retry/trap recipe, now checked for
# both callers in one place rather than once per skill.
#
# Every case is OFFLINE. measure.sh is driven through --fixture, which feeds the
# SAME code path live gh data takes, so these exercise the real classifier
# rather than a parallel reimplementation of it.
#
# HOME is sandboxed to a mktemp tree (script-usage-log-redirect.test.sh
# pattern), so the real ~/.claude is never touched. Both engines append a
# telemetry line to $HOME/.claude/script-usage.log on every invocation, so
# without this the suite would write into the developer's own log — and this
# header used to claim otherwise.
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
MEASURE="$REPO_ROOT/.claude/skills/review-stack-audit/measure.sh"
DRIFT="$REPO_ROOT/.claude/skills/review-stack-audit/drift.sh"
BASELINE_REAL="$REPO_ROOT/.claude/reference/review-stack-baseline.json"

TMP_DIR="$(mktemp -d)"
# u+rwx, not u+w: the unreadable-directory case leaves a dir at mode 000, and
# without READ and SEARCH restored neither chmod -R nor rm -rf can descend into
# it — the tree then survives the trap and leaks a temp dir on every run.
cleanup() { chmod -R u+rwx "$TMP_DIR" 2>/dev/null || true; rm -rf "$TMP_DIR"; }
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

  # report-path.test.sh runs a REPLICA of Step 7's claim block. On its own that
  # would keep passing while SKILL.md quietly lost the retry or the trap, so the
  # tests would certify a recipe nobody ships. That suite asserts these same three
  # lines for both callers; they are repeated here because they are Step 7's
  # contract and this is Step 7's suite — a reader editing this file should see
  # them fail here, not only in a file about a script.
  grep -qF 'if ( set -o noclobber; : > "$CANDIDATE" ) 2>/dev/null; then REPORT="$CANDIDATE"; break; fi' "$SKILL_MD" \
    && ok "skill: Step 7 still claims the resolved path with O_EXCL" \
    || fail "skill: Step 7 lost its 'set -o noclobber' claim — the resolve/write race is reopened"
  grep -qF 'for _attempt in 1 2 3 4 5; do' "$SKILL_MD" \
    && ok "skill: Step 7 still retries a lost claim instead of discarding the audit" \
    || fail "skill: Step 7 lost its claim retry loop — a lost race would discard the audit"
  grep -qF 'trap cleanup_report EXIT' "$SKILL_MD" \
    && ok "skill: Step 7 still clears its claim on failure" \
    || fail "skill: Step 7 lost its EXIT trap — a failed compose would park an empty file on the canonical name"
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


# ---------------------------------------------------------------------------
# measure.sh — single-repo output is byte-identical to before multi-repo mode
# (issue #1808)
#
# GOLDEN_OUT was captured from measure.sh as it stood at e08b08db, BEFORE
# --repos/--all-repos existed, by running exactly golden_transcript() below over
# GOLDEN_INPUTS — the measure.sh fixtures this suite builds inline, bundled one
# per key. Only the clock-derived fields are normalised (generated_at, until,
# days, and `since` on the default-window run); every other byte is compared.
# A diff here means the single-repo shape a baseline or report reads changed.
# Re-capture ONLY for an intended single-repo change, and say so in the PR.
# ---------------------------------------------------------------------------

GOLDEN_DIR="$REPO_ROOT/.claude/scripts/tests/fixtures/review-stack-audit"
GOLDEN_INPUTS="$GOLDEN_DIR/single-repo-inputs.json"
GOLDEN_OUT="$GOLDEN_DIR/single-repo.golden"

golden_normalize() {
  sed -E -e 's/^(  "generated_at": )"[^"]*"/\1"<GENERATED_AT>"/' \
         -e 's/^(    "until": )"[^"]*"/\1"<UNTIL>"/' \
         -e 's/^(    "days": )[0-9]+/\1<DAYS>/'
}

golden_transcript() {
  local measure="$1" name f
  for name in $(python3 -c 'import json,sys; print("\n".join(sorted(json.load(open(sys.argv[1])))))' "$GOLDEN_INPUTS"); do
    f="$TMP_DIR/golden-$name.json"
    python3 -c 'import json,sys; json.dump(json.load(open(sys.argv[1]))[sys.argv[2]], open(sys.argv[3], "w"))' \
      "$GOLDEN_INPUTS" "$name" "$f"
    printf '=== %s --json\n' "$name"
    "$measure" --fixture "$f" --since 2026-08-01 --json | golden_normalize || printf '!! rc=%s\n' "$?"
    printf '=== %s --summary\n' "$name"
    "$measure" --fixture "$f" --since 2026-08-01 --summary || printf '!! rc=%s\n' "$?"
  done
  # The two flag-variant cases read the `caps` input. Extract it explicitly
  # rather than reusing a file the loop above happened to write, so a renamed
  # or removed key fails loudly here instead of as an opaque transcript diff.
  f="$TMP_DIR/golden-flag-variants.json"
  python3 -c 'import json,sys; json.dump(json.load(open(sys.argv[1]))[sys.argv[2]], open(sys.argv[3], "w"))' \
    "$GOLDEN_INPUTS" caps "$f" || { printf '!! golden input "caps" missing\n'; return 1; }
  printf '=== caps --repo golden/override --json\n'
  "$measure" --fixture "$f" --repo golden/override --since 2026-08-01 --json | golden_normalize || printf '!! rc=%s\n' "$?"
  printf '=== caps default window --json\n'
  "$measure" --fixture "$f" --json | golden_normalize | sed -E 's/^(    "since": )"[^"]*"/\1"<SINCE>"/' || printf '!! rc=%s\n' "$?"
}

if [[ -r "$GOLDEN_INPUTS" && -r "$GOLDEN_OUT" ]]; then
  # Control: the golden must actually exercise the classifier, or an empty
  # transcript on both sides would compare equal for the wrong reason.
  golden_cases="$(grep -c '^=== .* --json$' "$GOLDEN_OUT")"
  [[ "$golden_cases" -ge 16 ]] || fail "golden: expected >= 16 --json cases in $GOLDEN_OUT, found $golden_cases"
  golden_transcript "$MEASURE" > "$TMP_DIR/golden-now.txt" 2>"$TMP_DIR/golden-now.err"
  if cmp -s "$TMP_DIR/golden-now.txt" "$GOLDEN_OUT"; then
    ok "golden: single-repo --json/--summary/--repo output is byte-identical to the pre-#1808 capture ($golden_cases cases)"
  else
    fail "golden: single-repo output drifted from the pre-#1808 capture:"
    diff "$GOLDEN_OUT" "$TMP_DIR/golden-now.txt" | head -40 >&2
  fi
else
  fail "golden: missing $GOLDEN_INPUTS or $GOLDEN_OUT"
fi

# ---------------------------------------------------------------------------
# Spend-ledger pricing files (issue #1809). Every ledger case passes its own
# --pricing file so a rate edit in the real pricing matrix cannot move a test's
# expected dollars. The default rates are deliberately not the real ones, so an
# assertion that accidentally read the real matrix cannot pass.
# ---------------------------------------------------------------------------

# pricing_write <path> [overrides-json]   e.g. '{"bugbot": null}'
# Every rate is known unless an override sets it to null.
pricing_write() {
  local overrides="${2:-}"
  [[ -n "$overrides" ]] || overrides='{}'
  python3 - "$1" "$overrides" <<'PY'
import json, sys
rates = {"coderabbit": 0.25, "bugbot": 2.0, "greptile": 0.5,
         "codeant": 60, "graphite": 15, "vercel": 0}
units = {"coderabbit": "file", "bugbot": "review", "greptile": "credit",
         "codeant": "month", "graphite": "month", "vercel": "month"}
rates.update(json.loads(sys.argv[2]))
doc = {"schema": "review-stack-rates/v1", "as_of": "2026-10-01", "caps": [],
       "tools": [{"key": k, "usd": v, "unit": units[k], "source": "test",
                  "retrieved": "2026-10-01"} for k, v in rates.items()]}
doc["tools"][0]["informational"] = True
for t in doc["tools"]:
    if t["key"] == "greptile":
        t["credits_per_review"] = 1
open(sys.argv[1], "w").write(
    "# Test pricing\n\nProse is never parsed: $999 per review.\n\n"
    "```json review-stack-rates\n%s\n```\n" % json.dumps(doc, indent=2))
PY
}
PRICING_FULL="$TMP_DIR/pricing-full.md"
pricing_write "$PRICING_FULL"

# ---------------------------------------------------------------------------
# measure.sh — multi-repo roll-up (issue #1808)
# ---------------------------------------------------------------------------

# Two repos built to differ on every summed axis, so a total that silently took
# one repo's figure (or double-counted one) cannot equal the sum by accident.
MULTI="$TMP_DIR/multi.json"
cat > "$MULTI" <<'JSON'
{"repos": [
 {"repo": "acme/one", "prs": [
   {"number": 1, "merged_at": "2026-08-01T00:00:00Z",
    "reviews": [{"user": "coderabbitai[bot]", "state": "APPROVED", "body": "> **Plan**: Pro"}],
    "pr_comments": [{"user": "coderabbitai[bot]", "body": "nit: rename"}],
    "issue_comments": []},
   {"number": 2, "merged_at": "2026-08-02T00:00:00Z", "reviews": [], "pr_comments": [],
    "issue_comments": [{"user": "cursor[bot]", "body": "Bugbot hit a usage or spend limit."}]}]},
 {"repo": "acme/two", "prs": [
   {"number": 1, "merged_at": "2026-08-03T00:00:00Z",
    "reviews": [{"user": "coderabbitai[bot]", "state": "CHANGES_REQUESTED", "body": ""},
                {"user": "codeant-ai[bot]", "state": "APPROVED", "body": ""}],
    "pr_comments": [{"user": "coderabbitai[bot]", "body": "bug"}, {"user": "greptile-apps[bot]", "body": "bug"}],
    "issue_comments": [{"user": "coderabbitai[bot]", "body": "Review limit reached."}]},
   {"number": 7, "merged_at": "2026-08-04T00:00:00Z", "reviews": [],
    "pr_comments": [{"user": "greptile-apps[bot]", "body": "race here"}],
    "issue_comments": [{"user": "codeant-ai[bot]", "body": "your quota for this org has been adjusted"}]}]}
]}
JSON

OUT="$TMP_DIR/multi.out.json"
"$MEASURE" --fixture "$MULTI" --repos acme/one,acme/two --since 2026-08-01 --json > "$OUT" \
  || fail "measure: multi-repo fixture run failed"
shape="$(jget "$OUT" "(d['repos'], sorted(d), len(d['per_repo']))")"
[[ "$shape" == "(['acme/one', 'acme/two'], ['generated_at', 'notes', 'per_repo', 'repos', 'source', 'tools', 'unclassified', 'unclassified_hits', 'window'], 2)" ]] \
  && ok "measure: multi-repo JSON carries repos[], per_repo[] and a top-level tools[]" \
  || fail "measure: unexpected multi-repo shape: $shape"

# Every summed field of every tool must equal the sum of the per-repo figures.
mismatch="$(jget "$OUT" "[(t['key'], f) for t in d['tools'] for f in ['prs_touched','review_objects','approved','changes_requested','inline_findings','issue_comments','sole_provider_on'] if t[f] != sum([x for x in r['tools'] if x['key']==t['key']][0][f] for r in d['per_repo'])]")"
[[ "$mismatch" == "[]" ]] && ok "measure: each total tools[] field is the sum of the per-repo figures" \
  || fail "measure: totals disagree with the per-repo sum: $mismatch"
# Pin real numbers too, so a sum over two empty documents cannot pass.
cr="$(jget "$OUT" "[(t['prs_touched'], t['review_objects'], t['approved'], t['changes_requested'], t['inline_findings']) for t in d['tools'] if t['key']=='coderabbit'][0]")"
[[ "$cr" == "(2, 2, 1, 1, 2)" ]] && ok "measure: coderabbit total = 2 PRs, 2 reviews, 1 approved, 1 changes-requested, 2 findings" \
  || fail "measure: coderabbit total wrong, got $cr"
gs="$(jget "$OUT" "[(t['sole_provider_on'], t['sole_provider_prs']) for t in d['tools'] if t['key']=='greptile'][0]")"
[[ "$gs" == "(1, ['acme/two#7'])" ]] && ok "measure: sole_provider_on stays a count; its PRs are listed repo-qualified" \
  || fail "measure: greptile sole-provider total wrong, got $gs"

# Repo-qualified identifiers: PR #1 exists in BOTH repos, so a bare number in
# the total would be ambiguous — exactly the case the qualification is for.
caps="$(jget "$OUT" "sorted((c['pr'], c['kind']) for t in d['tools'] for c in t['cap_signals'])")"
[[ "$caps" == "[('acme/one#2', 'spend_limit'), ('acme/two#1', 'rate_limit')]" ]] \
  && ok "measure: total cap_signals carry owner/name#N, not bare PR numbers" \
  || fail "measure: cap_signals not repo-qualified: $caps"
uc="$(jget "$OUT" "[u['pr'] for u in d['unclassified']]")"
[[ "$uc" == "['acme/two#7']" ]] && ok "measure: merged unclassified[] entries are repo-qualified" \
  || fail "measure: unclassified not repo-qualified: $uc"
st="$(jget "$OUT" "[(t['key'], t['observed_state'], t['cap_kinds']) for t in d['tools'] if t['key'] in ('coderabbit','bugbot','vercel')]")"
[[ "$st" == "[('coderabbit', 'capped', ['rate_limit']), ('bugbot', 'capped', ['spend_limit']), ('vercel', 'silent', [])]" ]] \
  && ok "measure: total observed_state and cap_kinds are recomputed across repos" \
  || fail "measure: total state wrong: $st"
# The per-repo entries keep bare PR numbers: they are the single-repo document.
inner="$(jget "$OUT" "[c['pr'] for r in d['per_repo'] for t in r['tools'] for c in t['cap_signals']]")"
[[ "$inner" == "[2, 1]" ]] && ok "measure: per_repo[] documents keep their own bare PR numbers" \
  || fail "measure: per_repo cap_signals changed shape: $inner"

# per_repo[i] IS the single-repo document: measure each repo alone through the
# single-repo path and compare whole documents (clock fields aside). A multi-repo
# run is a ledger run (#1809), so each per_repo tool also carries the two spend
# fields — and ONLY those, which is what stripping them and comparing proves.
python3 - "$MULTI" "$TMP_DIR" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
for e in d["repos"]:
    name = e["repo"].replace("/", "_")
    json.dump({"repo": e["repo"], "prs": e["prs"]}, open("%s/single-%s.json" % (sys.argv[2], name), "w"))
PY
same=1
idx=0
for r in acme/one acme/two; do
  "$MEASURE" --fixture "$TMP_DIR/single-${r/\//_}.json" --since 2026-08-01 --json > "$TMP_DIR/single-$idx.out.json" || same=0
  python3 - "$OUT" "$TMP_DIR/single-$idx.out.json" "$idx" <<'PY' || same=0
import json, sys
multi = json.load(open(sys.argv[1]))["per_repo"][int(sys.argv[3])]
single = json.load(open(sys.argv[2]))
for t in multi["tools"]:
    if t.get("spend_source") not in ("receipt", "estimate", "flat", "none") or "spend_usd" not in t:
        sys.exit(1)
    del t["spend_usd"], t["spend_source"]
for doc in (multi, single):
    doc.pop("generated_at", None)
sys.exit(0 if multi == single else 1)
PY
  idx=$((idx + 1))
done
[[ $same -eq 1 ]] && ok "measure: each per_repo[] entry equals that repo's single-repo document, plus spend fields" \
  || fail "measure: a per_repo[] entry differs from the single-repo document for the same repo"

# drift.sh must read the roll-up unchanged — that is why the total lives in a
# top-level tools[] rather than under a new key.
"$DRIFT" --snapshot "$OUT" --baseline "$BASE" --json > "$TMP_DIR/multi-drift.json" 2>/dev/null
rc=$?
[[ $rc -eq 0 || $rc -eq 3 ]] && [[ "$(jget "$TMP_DIR/multi-drift.json" "type(d['drift_count']).__name__")" == "int" ]] \
  && ok "drift: drift.sh analyses a multi-repo roll-up unchanged (rc=$rc)" \
  || fail "drift: drift.sh rejected the multi-repo roll-up (rc=$rc)"

# A one-per-line --repos value keeps every line, not just the first.
"$MEASURE" --fixture "$MULTI" --repos $'acme/one\nacme/two' --json > "$TMP_DIR/multi-nl.json" \
  || fail "measure: newline-separated --repos run failed"
r="$(jget "$TMP_DIR/multi-nl.json" "d['repos']")"
[[ "$r" == "['acme/one', 'acme/two']" ]] && ok "measure: --repos accepts newline-separated entries without dropping any" \
  || fail "measure: newline-separated --repos measured $r"

# A multi-repo fixture with no repo flag measures every repo it carries.
"$MEASURE" --fixture "$MULTI" --json > "$TMP_DIR/multi-implicit.json" || fail "measure: implicit multi-repo fixture run failed"
r="$(jget "$TMP_DIR/multi-implicit.json" "d['repos']")"
[[ "$r" == "['acme/one', 'acme/two']" ]] && ok "measure: a multi-repo fixture with no flag measures every repo in it" \
  || fail "measure: implicit multi-repo run measured $r"
# ...and, being a multi-repo run, it is a ledger run: every per_repo and total
# tool carries both spend fields, exactly as with --repos.
r="$(jget "$TMP_DIR/multi-implicit.json" "all('spend_usd' in t and t.get('spend_source') in ('receipt', 'estimate', 'flat', 'none') for t in d['tools'] + [x for doc in d['per_repo'] for x in doc['tools']])")"
[[ "$r" == "True" ]] && ok "measure: an implicit multi-repo fixture run carries the spend fields" \
  || fail "measure: implicit multi-repo run lacks spend fields ($r)"

# --summary: one block per repo, then one total block whose prs per tool is the
# sum of the repo blocks' (Test Plan item 2, offline). Multi-repo is ledger mode,
# so every line carries the two spend columns (#1809): 7 fields, never 5.
"$MEASURE" --fixture "$MULTI" --repos acme/one,acme/two --summary > "$TMP_DIR/multi.summary" \
  || fail "measure: multi-repo --summary failed"
widths="$(awk -F'\t' '!/^#/ && NF { print NF }' "$TMP_DIR/multi.summary" | sort -u | tr '\n' ' ')"
[[ "$widths" == "7 " ]] && ok "measure: multi-repo --summary lines carry spend_usd and spend_source columns" \
  || fail "measure: multi-repo --summary column counts: $widths"
heads="$(grep '^# ' "$TMP_DIR/multi.summary" | tr '\n' '|')"
[[ "$heads" == "# repo: acme/one|# repo: acme/two|# total: 2 repos|" ]] \
  && ok "measure: multi-repo --summary prints two repo blocks then one total block" \
  || fail "measure: unexpected --summary block headers: $heads"
sum_check="$(awk -F'\t' '
  /^# total:/ { tot = 1; next }
  /^# repo:/  { tot = 0; next }
  NF >= 5 { if (tot) t[$1] = $3; else s[$1] += $3 }
  END { bad = 0; n = 0; for (k in t) { n++; if (t[k] != s[k]) bad = 1 } print (n == 6 && !bad) ? "ok" : "bad" }
' "$TMP_DIR/multi.summary")"
[[ "$sum_check" == "ok" ]] && ok "measure: the total block's prs_touched per tool equals the sum of the repo blocks" \
  || fail "measure: --summary total does not equal the sum of the repo blocks"

# Truncation propagates, and notes merge with the repo that produced them.
TRUNC_MULTI="$TMP_DIR/multi-trunc.json"
python3 - "$MULTI" "$TRUNC_MULTI" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d["repos"][1]["truncated"] = True       # ONLY acme/two's listing hit --limit
json.dump(d, open(sys.argv[2], "w"))
PY
OUT="$TMP_DIR/multi-trunc.out.json"
# A fully-priced --pricing file: with every rate known, the ledger adds no
# run-wide note, so the merged notes below are exactly the repos' own.
"$MEASURE" --fixture "$TRUNC_MULTI" --repos acme/one,acme/two --pricing "$PRICING_FULL" --json > "$OUT" \
  || fail "measure: truncated multi-repo run failed"
w="$(jget "$OUT" "(d['window']['truncated'], d['window']['pr_count'], [r['window']['truncated'] for r in d['per_repo']])")"
[[ "$w" == "(True, 4, [False, True])" ]] \
  && ok "measure: one truncated repo makes window.truncated true; pr_count is summed" \
  || fail "measure: truncation/pr_count roll-up wrong: $w"
notes="$(jget "$OUT" "[n.split(':')[0] for n in d['notes']]")"
[[ "$notes" == "['acme/two', 'acme/two']" ]] \
  && ok "measure: notes merge into one array, each tagged with its repo" \
  || fail "measure: merged notes wrong: $notes"
case "$(jget "$OUT" "d['notes'][0]")" in
  "acme/two: Sample hit the --limit"*) ok "measure: the truncation note survives the merge" ;;
  *) fail "measure: truncation note missing from merged notes" ;;
esac

# Usage conflicts are exit 2, before anything is measured.
expect_usage_error() {
  "$MEASURE" --fixture "$MULTI" "$@" >/dev/null 2>&1
  local rc=$?
  [[ $rc -eq 2 ]] && ok "measure: '$*' is a usage error (exit 2)" \
    || fail "measure: '$*' should exit 2, got $rc"
}
expect_usage_error --repo x/y --repos a/b
expect_usage_error --repo x/y --all-repos
expect_usage_error --repos a/b --all-repos
expect_usage_error --repos a/b,bogus
expect_usage_error --repos "acme/my repo"
expect_usage_error --repos acme/..
expect_usage_error --repos ../acme

# Fail closed: one repo that cannot be measured means no output at all.
"$MEASURE" --fixture "$MULTI" --repos acme/one,acme/missing --json > "$TMP_DIR/multi-missing.out" 2>/dev/null
rc=$?
[[ $rc -eq 1 && ! -s "$TMP_DIR/multi-missing.out" ]] \
  && ok "measure: a repo that fails to measure fails the whole run with empty stdout" \
  || fail "measure: partial multi-repo run leaked output or wrong rc ($rc)"
"$MEASURE" --fixture "$TMP_DIR/caps.json" --repos acme/one --json >/dev/null 2>&1
[[ $? -eq 1 ]] && ok "measure: multi-repo mode refuses a single-repo fixture" \
  || fail "measure: single-repo fixture in multi-repo mode should exit 1"
"$MEASURE" --fixture "$MULTI" --repo acme/one --json >/dev/null 2>&1
[[ $? -eq 1 ]] && ok "measure: --repo refuses a multi-repo fixture rather than guessing" \
  || fail "measure: --repo against a multi-repo fixture should exit 1"

# --all-repos goes through review-repos.sh; REVIEW_REPOS is its first source.
# Both runs inherit the HOME="$TMP_DIR/home" exported at the top of this suite,
# so review-repos.sh's telemetry append and its default ~/.claude/account-config.md
# lookup stay inside the sandbox.
REVIEW_REPOS="acme/two" "$MEASURE" --fixture "$MULTI" --all-repos --json > "$TMP_DIR/multi-all.json" \
  || fail "measure: --all-repos with REVIEW_REPOS failed"
r="$(jget "$TMP_DIR/multi-all.json" "d['repos']")"
[[ "$r" == "['acme/two']" ]] && ok "measure: --all-repos measures exactly the registered list" \
  || fail "measure: --all-repos measured $r"
REVIEW_REPOS="acme/two,not-a-repo" "$MEASURE" --fixture "$MULTI" --all-repos --json > "$TMP_DIR/multi-all-bad.out" 2>/dev/null
rc=$?
[[ $rc -eq 1 && ! -s "$TMP_DIR/multi-all-bad.out" ]] \
  && ok "measure: --all-repos fails closed when the registered list cannot be resolved" \
  || fail "measure: --all-repos with an unresolvable list should exit 1 silently (rc=$rc)"
# A fixture run must never reach the network: with no REVIEW_REPOS and no
# config list, --all-repos under --fixture fails rather than discovering live.
# PATH holds a gh stub that records any call, so "it failed" cannot pass while
# discovery quietly ran.
mkdir -p "$TMP_DIR/gh-trap"
printf '#!/bin/sh\necho called >> "%s"\nexit 1\n' "$TMP_DIR/gh-trap/calls" > "$TMP_DIR/gh-trap/gh"
chmod +x "$TMP_DIR/gh-trap/gh"
env -u REVIEW_REPOS CLAUDE_ACCOUNT_CONFIG="$TMP_DIR/no-such-account-config.md" PATH="$TMP_DIR/gh-trap:$PATH" \
  "$MEASURE" --fixture "$MULTI" --all-repos --json > "$TMP_DIR/multi-all-offline.out" 2>/dev/null
rc=$?
[[ $rc -eq 1 && ! -s "$TMP_DIR/multi-all-offline.out" && ! -e "$TMP_DIR/gh-trap/calls" ]] \
  && ok "measure: --fixture --all-repos never falls through to live gh discovery" \
  || fail "measure: --fixture --all-repos reached gh or did not fail closed (rc=$rc)"

# ---------------------------------------------------------------------------
# measure.sh — spend ledger (issue #1809)
# ---------------------------------------------------------------------------

# Test Plan item 1. Exactly the issue's signals — one $3.25 CodeRabbit receipt,
# three Cursor Bugbot runs, one @greptileai trigger — plus noise that must add
# nothing: a CodeRabbit comment quoting a receipt mid-sentence, a receipt
# created in the window but last edited after it (timed by the edit), a duplicate
# run id, a run under another check name, a `Cursor
# Bugbot` run from another app or from no app, a run and a
# receipt outside the window, a human quoting a receipt, and Greptile's own
# footer naming its handle. Run under a fixed --since/--until so no figure
# depends on today's date.
LEDGER_F="$TMP_DIR/ledger.json"
fixture_write "$LEDGER_F" '[
 {"number":1,"merged_at":"2025-10-05T00:00:00Z","reviews":[],"pr_comments":[],
  "issue_comments":[
    {"user":"coderabbitai[bot]","created_at":"2025-10-02T10:00:00Z","body":"### Usage-based review receipt\n- Reviewed files: 13\n- Charged: $3.25\n"},
    {"user":"coderabbitai[bot]","created_at":"2025-09-30T23:59:59Z","body":"- Charged: $8.25"},
    {"user":"auerbachb","created_at":"2025-10-03T10:00:00Z","body":"The bot said Charged: $99.00 here"},
    {"user":"coderabbitai[bot]","created_at":"2025-10-06T10:00:00Z","body":"Walkthrough: the ledger sums each `Charged: $7.00` line it finds."},
    {"user":"coderabbitai[bot]","created_at":"2025-10-08T10:00:00Z","updated_at":"2025-11-05T10:00:00Z","body":"- Reviewed files: 4\n- Charged: $4.00\n"},
    {"user":"auerbachb","created_at":"2025-10-04T10:00:00Z","body":"@greptileai review please, @greptileai"},
    {"user":"greptile-apps[bot]","created_at":"2025-10-04T11:00:00Z","body":"Mention @greptileai to ask a question"}],
  "check_runs":[
    {"id":11,"name":"Cursor Bugbot","app":"cursor","started_at":"2025-10-01T00:00:00Z"},
    {"id":12,"name":"Cursor Bugbot","app":"cursor","started_at":"2025-10-15T12:00:00Z"},
    {"total_count":2,"check_runs":[
      {"id":13,"name":"Cursor Bugbot","app":"cursor","started_at":"2025-10-31T23:59:59Z"},
      {"id":12,"name":"Cursor Bugbot","app":"cursor","started_at":"2025-10-15T12:00:00Z"}]},
    {"id":14,"name":"CodeRabbit","started_at":"2025-10-02T00:00:00Z"},
    {"id":16,"name":"Cursor Bugbot","app":"impostor","started_at":"2025-10-10T00:00:00Z"},
    {"id":17,"name":"Cursor Bugbot","started_at":"2025-10-11T00:00:00Z"},
    {"id":15,"name":"Cursor Bugbot","app":"cursor","started_at":"2025-11-01T00:00:00Z"}]}]'
OUT="$TMP_DIR/ledger.out.json"
"$MEASURE" --fixture "$LEDGER_F" --ledger --pricing "$PRICING_FULL" --since 2025-10-01 --until 2025-10-31 --json > "$OUT" \
  || fail "measure: ledger fixture run failed"
spend="$(jget "$OUT" "[(t['key'], t['spend_usd'], t['spend_source']) for t in d['tools']]")"
[[ "$spend" == "[('coderabbit', 3.25, 'receipt'), ('codeant', 62.0, 'flat'), ('bugbot', 6.0, 'estimate'), ('greptile', 0.5, 'estimate'), ('graphite', 15.5, 'flat'), ('vercel', 0.0, 'flat')]" ]] \
  && ok "ledger: \$3.25 receipt, 3 runs x \$2.00 estimate, 1 trigger x \$0.50 estimate, flat fees x 31/30" \
  || fail "ledger: spend figures wrong: $spend"
win="$(jget "$OUT" "(d['window']['since'], d['window']['until'], d['window']['days'])")"
[[ "$win" == "('2025-10-01', '2025-10-31', 31)" ]] \
  && ok "ledger: --since 2025-10-01 --until 2025-10-31 bounds the window to those dates, 31 days inclusive" \
  || fail "ledger: window not bounded by --since/--until: $win"

# Negative control for the case above: the noise alone prices to nothing, so
# the figures above cannot have come from it.
NOISE_F="$TMP_DIR/ledger-noise.json"
python3 - "$LEDGER_F" "$NOISE_F" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
pr = d["prs"][0]
pr["issue_comments"] = [c for c in pr["issue_comments"]
                        if not (c["user"] == "coderabbitai[bot]" and "3.25" in c["body"])
                        and "review please" not in c["body"]]
pr["check_runs"] = [r for r in pr["check_runs"] if r.get("id") in (14, 15, 16, 17)]
json.dump(d, open(sys.argv[2], "w"))
PY
"$MEASURE" --fixture "$NOISE_F" --ledger --pricing "$PRICING_FULL" --since 2025-10-01 --until 2025-10-31 --json > "$OUT" \
  || fail "measure: ledger noise fixture run failed"
spend="$(jget "$OUT" "[(t['key'], t['spend_usd'], t['spend_source']) for t in d['tools'] if t['key'] in ('coderabbit','bugbot','greptile')]")"
[[ "$spend" == "[('coderabbit', 0.0, 'receipt'), ('bugbot', 0.0, 'estimate'), ('greptile', 0.0, 'estimate')]" ]] \
  && ok "ledger: out-of-window, non-bot, wrong-name and self-mention events price to nothing (CodeRabbit floor 0.00 receipt)" \
  || fail "ledger: noise leaked into spend: $spend"

# Test Plan item 2: an unknown rate is null, labelled none, and named in a note
# — never 0. The receipt-priced and other rate-priced tools are unaffected.
PRICING_NULL_BB="$TMP_DIR/pricing-null-bugbot.md"
pricing_write "$PRICING_NULL_BB" '{"bugbot": null}'
OUT="$TMP_DIR/ledger-null.out.json"
"$MEASURE" --fixture "$LEDGER_F" --ledger --pricing "$PRICING_NULL_BB" --since 2025-10-01 --until 2025-10-31 --json > "$OUT" \
  || fail "measure: null-rate ledger run failed"
bb="$(jget "$OUT" "[(t['spend_usd'], t['spend_source']) for t in d['tools'] if t['key']=='bugbot'][0]")"
[[ "$bb" == "(None, 'none')" ]] && ok "ledger: a null BugBot rate yields spend_usd null / none, never 0" \
  || fail "ledger: null BugBot rate produced $bb"
case "$(jget "$OUT" "' | '.join(d['notes'])")" in
  *"bugbot's per-review rate is null"*) ok "ledger: a note names the missing BugBot rate" ;;
  *) fail "ledger: no note names the missing BugBot rate" ;;
esac
gr="$(jget "$OUT" "[(t['spend_usd'], t['spend_source']) for t in d['tools'] if t['key']=='greptile'][0]")"
[[ "$gr" == "(0.5, 'estimate')" ]] && ok "ledger: one null rate leaves every other tool's figure intact" \
  || fail "ledger: greptile disturbed by a null BugBot rate: $gr"
# The summary prints the null as `null`, not as 0.00 or a blank column.
"$MEASURE" --fixture "$LEDGER_F" --ledger --pricing "$PRICING_NULL_BB" --since 2025-10-01 --until 2025-10-31 --summary > "$TMP_DIR/ledger-null.summary" \
  || fail "measure: null-rate ledger --summary failed"
line="$(grep '^bugbot' "$TMP_DIR/ledger-null.summary")"
[[ "$line" == $'bugbot\tsilent\t0\t0\t0\tnull\tnone' ]] \
  && ok "ledger: --summary appends spend_usd/spend_source and prints a null figure as 'null'" \
  || fail "ledger: unexpected ledger --summary line: $line"

# Undated events cannot be placed in any window: they are left out and counted
# in a note rather than silently included or silently dropped.
UNDATED_F="$TMP_DIR/ledger-undated.json"
fixture_write "$UNDATED_F" '[
 {"number":1,"merged_at":"2025-10-05T00:00:00Z","reviews":[],"pr_comments":[],
  "issue_comments":[{"user":"coderabbitai[bot]","body":"- Charged: $1.00"}],
  "check_runs":[{"id":1,"name":"Cursor Bugbot","app":"cursor"}]}]'
OUT="$TMP_DIR/ledger-undated.out.json"
"$MEASURE" --fixture "$UNDATED_F" --ledger --pricing "$PRICING_FULL" --since 2025-10-01 --until 2025-10-31 --json > "$OUT" \
  || fail "measure: undated-event ledger run failed"
und="$(jget "$OUT" "([t['spend_usd'] for t in d['tools'] if t['key'] in ('coderabbit','bugbot')], sum(1 for n in d['notes'] if 'carried no timestamp' in n))")"
[[ "$und" == "([0.0, 0.0], 2)" ]] && ok "ledger: undated receipts and runs are excluded and each kind is counted in a note" \
  || fail "ledger: undated events mishandled: $und"

# Legacy parity: without --ledger (and without --repos/--all-repos) the snapshot
# carries no spend key and the summary keeps its five columns — --until included.
"$MEASURE" --fixture "$LEDGER_F" --since 2025-10-01 --until 2025-10-31 --json > "$TMP_DIR/legacy.out.json" \
  || fail "measure: legacy run with --until failed"
leak="$(jget "$TMP_DIR/legacy.out.json" "sorted({k for t in d['tools'] for k in t if k.startswith('spend')})")"
[[ "$leak" == "[]" ]] && ok "ledger: a run without --ledger carries no spend_* keys" \
  || fail "ledger: legacy run leaked $leak"
"$MEASURE" --fixture "$LEDGER_F" --summary > "$TMP_DIR/legacy.summary" || fail "measure: legacy --summary failed"
widths="$(awk -F'\t' '{ print NF }' "$TMP_DIR/legacy.summary" | sort -u | tr '\n' ' ')"
[[ "$widths" == "5 " ]] && ok "ledger: the legacy --summary keeps exactly five columns" \
  || fail "ledger: legacy --summary column counts: $widths"

# Flag contract: --until needs --since and may not precede it; --pricing is a
# ledger flag; an unreadable --pricing fails the run (exit 1), not the usage.
expect_ledger_rc() {
  local want="$1"; shift
  "$MEASURE" --fixture "$LEDGER_F" "$@" >/dev/null 2>&1
  local rc=$?
  [[ $rc -eq $want ]] && ok "ledger: '$*' exits $want" || fail "ledger: '$*' should exit $want, got $rc"
}
expect_ledger_rc 2 --until 2025-10-31
expect_ledger_rc 2 --ledger --until 2025-10-31
expect_ledger_rc 2 --days 5 --until 2025-10-31
expect_ledger_rc 2 --since 2025-10-31 --until 2025-10-01
expect_ledger_rc 2 --since 2025-10-01 --until 2026/10/31
expect_ledger_rc 2 --pricing "$PRICING_FULL"
expect_ledger_rc 1 --ledger --pricing "$TMP_DIR/no-such-pricing.md"
expect_ledger_rc 0 --since 2025-10-31 --until 2025-10-31

# A --since that has not arrived yet gives a negative window.days; the flat fee
# for a window that has not begun is 0.00, never negative.
"$MEASURE" --fixture "$LEDGER_F" --ledger --pricing "$PRICING_FULL" --since 2099-01-01 --json > "$TMP_DIR/ledger-future.json" \
  || fail "measure: future --since ledger run failed"
r="$(jget "$TMP_DIR/ledger-future.json" "(d['window']['days'] < 0, [(t['spend_usd'], t['spend_source']) for t in d['tools'] if t['key'] == 'codeant'])")"
[[ "$r" == "(True, [(0.0, 'flat')])" ]] && ok "ledger: a window that has not begun bills a flat fee of 0.00, never negative" \
  || fail "ledger: future --since flat fee wrong: $r"
"$MEASURE" --fixture "$LEDGER_F" --ledger --pricing "$PRICING_FULL" --since 2099-01-01 --until 2099-01-31 --json > "$TMP_DIR/ledger-future-bounded.json" \
  || fail "measure: future bounded ledger run failed"
r="$(jget "$TMP_DIR/ledger-future-bounded.json" "(d['window']['days'], [(t['spend_usd'], t['spend_source']) for t in d['tools'] if t['key'] == 'codeant'])")"
[[ "$r" == "(31, [(0.0, 'flat')])" ]] && ok "ledger: a bounded window wholly in the future keeps window.days but bills no flat fee" \
  || fail "ledger: future bounded window flat fee wrong: $r"
# A bounded window straddling today bills only its elapsed days: from --since
# through today, inclusive ($60/month x d/30 = $2.00 x d). The probe accepts the
# previous day too, in case the run crossed UTC midnight before the check.
"$MEASURE" --fixture "$LEDGER_F" --ledger --pricing "$PRICING_FULL" --since 2025-10-01 --until 2099-12-31 --json > "$TMP_DIR/ledger-straddle.json" \
  || fail "measure: straddling ledger run failed"
ledger_straddle_probe() {
  python3 - "$TMP_DIR/ledger-straddle.json" <<'PY'
import json, sys
from datetime import date, datetime, timezone
d = json.load(open(sys.argv[1]))
codeant = [t["spend_usd"] for t in d["tools"] if t["key"] == "codeant"][0]
elapsed = (datetime.now(timezone.utc).date() - date(2025, 10, 1)).days + 1
full = (date(2099, 12, 31) - date(2025, 10, 1)).days + 1
fee_ok = any(abs(codeant - 2.0 * e) < 0.005 for e in (elapsed, elapsed - 1))
print("ok" if d["window"]["days"] == full and fee_ok
      else "BAD days=%s codeant=%s elapsed=%s" % (d["window"]["days"], codeant, elapsed))
PY
}
r="$(ledger_straddle_probe)"
[[ "$r" == "ok" ]] && ok "ledger: a bounded window straddling today bills only its elapsed days, never the future ones" \
  || fail "ledger: straddling window flat fee wrong: $r"

# HOME unset: `set -u` must not abort the published-path lookups; the
# checkout's own library and the --pricing file still run the ledger.
env -u HOME "$MEASURE" --fixture "$LEDGER_F" --ledger --pricing "$PRICING_FULL" --since 2025-10-01 --until 2025-10-31 --json > "$TMP_DIR/ledger-nohome.json" 2>"$TMP_DIR/ledger-nohome.err"
rc=$?
r="$(jget "$TMP_DIR/ledger-nohome.json" "[t['spend_source'] for t in d['tools'] if t['key'] == 'codeant']" 2>/dev/null)"
[[ $rc -eq 0 && "$r" == "['flat']" ]] && ok "ledger: runs with HOME unset (set -u never trips on the published-path lookups)" \
  || fail "ledger: HOME-unset ledger run failed (rc=$rc, codeant=$r): $(head -c 300 "$TMP_DIR/ledger-nohome.err")"

# Test Plan item 3: two repos. Each tool's total is the exact sum of its
# per-repo figures, and CodeAnt's flat fee is split by its prs_touched share
# (3 PRs vs 1) into parts that sum to the prorated fee to the cent.
LEDGER_MULTI="$TMP_DIR/ledger-multi.json"
cat > "$LEDGER_MULTI" <<'JSON'
{"repos": [
 {"repo": "acme/one", "prs": [
   {"number": 1, "merged_at": "2025-10-02T00:00:00Z", "reviews": [{"user": "codeant-ai[bot]", "state": "APPROVED", "body": ""}],
    "pr_comments": [], "issue_comments": [{"user": "coderabbitai[bot]", "created_at": "2025-10-02T01:00:00Z", "body": "- Charged: $1.10"}],
    "check_runs": [{"id": 1, "name": "Cursor Bugbot", "app": "cursor", "started_at": "2025-10-02T00:00:00Z"}]},
   {"number": 2, "merged_at": "2025-10-03T00:00:00Z", "reviews": [{"user": "codeant-ai[bot]", "state": "APPROVED", "body": ""}],
    "pr_comments": [], "issue_comments": [{"user": "auerbachb", "created_at": "2025-10-03T00:00:00Z", "body": "@greptileai"}]},
   {"number": 3, "merged_at": "2025-10-04T00:00:00Z", "reviews": [{"user": "codeant-ai[bot]", "state": "APPROVED", "body": ""}],
    "pr_comments": [], "issue_comments": []}]},
 {"repo": "acme/two", "prs": [
   {"number": 1, "merged_at": "2025-10-05T00:00:00Z", "reviews": [{"user": "codeant-ai[bot]", "state": "APPROVED", "body": ""}],
    "pr_comments": [], "issue_comments": [{"user": "coderabbitai[bot]", "created_at": "2025-10-05T01:00:00Z", "body": "- Charged: $2.20"}],
    "check_runs": [{"id": 9, "name": "Cursor Bugbot", "app": "cursor", "started_at": "2025-10-05T00:00:00Z"},
                   {"id": 10, "name": "Cursor Bugbot", "app": "cursor", "started_at": "2025-10-06T00:00:00Z"}]}]}
]}
JSON
OUT="$TMP_DIR/ledger-multi.out.json"
"$MEASURE" --fixture "$LEDGER_MULTI" --repos acme/one,acme/two --pricing "$PRICING_FULL" --since 2025-10-01 --until 2025-10-31 --json > "$OUT" \
  || fail "measure: two-repo ledger run failed"
# Probes below are functions, not heredocs inside $( ): bash 3.2 (macOS) scans
# a command substitution's raw text for parens and quotes, and Python source
# inside one mis-parses there.
ledger_sum_probe() {
  python3 - "$1" <<'PY'
import json, sys
from decimal import Decimal
d = json.load(open(sys.argv[1]))
bad = []
for t in d["tools"]:
    parts = [[x for x in r["tools"] if x["key"] == t["key"]][0]["spend_usd"] for r in d["per_repo"]]
    if sum(Decimal(repr(p)) for p in parts) != Decimal(repr(t["spend_usd"])):
        bad.append(t["key"])
print("ok" if not bad else "BAD %s" % bad)
PY
}
sums="$(ledger_sum_probe "$OUT")"
[[ "$sums" == "ok" ]] && ok "ledger: every tool's total spend_usd is the exact sum of its per-repo figures" \
  || fail "ledger: totals disagree with per-repo sums: $sums"
alloc="$(jget "$OUT" "([[x for x in r['tools'] if x['key']=='codeant'][0]['spend_usd'] for r in d['per_repo']], [t['spend_usd'] for t in d['tools'] if t['key']=='codeant'][0])")"
[[ "$alloc" == "([46.5, 15.5], 62.0)" ]] \
  && ok "ledger: CodeAnt's \$62.00 (31 days of \$60) splits 46.50/15.50 by prs_touched 3:1 and sums back" \
  || fail "ledger: CodeAnt flat allocation wrong: $alloc"
tot="$(jget "$OUT" "[(t['key'], t['spend_usd'], t['spend_source']) for t in d['tools'] if t['key'] in ('coderabbit','bugbot','greptile')]")"
[[ "$tot" == "[('coderabbit', 3.3, 'receipt'), ('bugbot', 6.0, 'estimate'), ('greptile', 0.5, 'estimate')]" ]] \
  && ok "ledger: two-repo totals carry real figures (\$1.10+\$2.20 receipts, 3 runs, 1 trigger)" \
  || fail "ledger: two-repo totals wrong: $tot"
# Null propagates: an unknown BugBot rate nulls every repo and so the total.
"$MEASURE" --fixture "$LEDGER_MULTI" --repos acme/one,acme/two --pricing "$PRICING_NULL_BB" --since 2025-10-01 --until 2025-10-31 --json > "$OUT" \
  || fail "measure: two-repo null-rate ledger run failed"
bbt="$(jget "$OUT" "([[x for x in r['tools'] if x['key']=='bugbot'][0]['spend_usd'] for r in d['per_repo']], [(t['spend_usd'], t['spend_source']) for t in d['tools'] if t['key']=='bugbot'][0])")"
[[ "$bbt" == "([None, None], (None, 'none'))" ]] \
  && ok "ledger: a null per-repo BugBot figure makes the BugBot total null, never a partial sum" \
  || fail "ledger: null did not propagate to the total: $bbt"

# The library directly: the allocation and sum rules the totals rest on,
# including the cases a fixture cannot reach (a null in only ONE repo, a cent
# that does not divide evenly, a tool that touched nothing anywhere).
ledger_lib_probe() {
  python3 - "$REPO_ROOT/.claude/scripts/lib" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import review_ledger as L
D = L.Decimal
checks = [
    ("one-null-repo-nulls-total", L.sum_spend([(D("1.00"), "estimate"), (None, "none")]) == (None, "none")),
    ("sum-exact", L.sum_spend([(D("0.10"), "receipt"), (D("0.20"), "receipt")]) == (D("0.30"), "receipt")),
    ("odd-cent-sums-back", sum(L.allocate(D("10.00"), [1, 1, 1])) == D("10.00")),
    ("odd-cent-split", L.allocate(D("10.00"), [1, 1, 1]) == [D("3.34"), D("3.33"), D("3.33")]),
    ("all-zero-weights-split-evenly", L.allocate(D("48.00"), [0, 0]) == [D("24.00"), D("24.00")]),
    ("prorate-30-days-is-one-month", L.prorate_flat(D("48"), 30) == D("48.00")),
    ("prorate-negative-window-is-zero", L.prorate_flat(D("48"), -5) == D("0.00")),
    ("bugbot-publisher-only", [r["id"] for r in L.bugbot_runs([
        {"id": 1, "name": "Cursor Bugbot", "app": {"slug": "cursor"}},
        {"id": 2, "name": "Cursor Bugbot", "app": "cursor"},
        {"id": 3, "name": "Cursor Bugbot", "app": {"slug": "impostor"}},
        {"id": 4, "name": "Cursor Bugbot"}])] == [1, 2]),
    ("zero-receipts-is-a-floor", L.compute_spend("coderabbit", {"charges": []}, None, 30) == (D("0.00"), "receipt")),
    ("no-rates-is-none-not-zero", L.compute_spend("bugbot", {"bugbot_runs": 3}, None, 30) == (None, "none")),
    ("unknown-credits-is-none", L.compute_spend("greptile", {"greptile_triggers": 2},
        {"usd": {"greptile": D("0.5")}, "credits_per_review": None}, 30) == (None, "none")),
    ("comma-and-bold-receipts", [e["amount"] for e in L.extract_charges([{"user": "coderabbitai[bot]", "body": "**Charged:** $1,234.50"}])] == [D("1234.50")]),
    ("receipt-timed-by-last-edit", [e["amount"] for e in L.filter_window(L.extract_charges([
        {"user": "coderabbitai[bot]", "created_at": "2025-09-20T00:00:00Z", "updated_at": "2025-10-07T00:00:00Z", "body": "- Charged: $1.00"},
        {"user": "coderabbitai[bot]", "created_at": "2025-10-02T00:00:00Z", "updated_at": "2025-11-02T00:00:00Z", "body": "- Charged: $2.00"},
        {"user": "coderabbitai[bot]", "created_at": "2025-10-03T00:00:00Z", "body": "- Charged: $3.00"}]),
        "2025-10-01", "2025-10-31", "at")[0]] == [D("1.00"), D("3.00")]),
    ("receipt-is-a-line-not-a-quote", [e["amount"] for e in L.extract_charges([{"user": "coderabbitai[bot]",
        "body": "- Reviewed files: 2\n- Charged: $0.50\nThe walkthrough quotes Charged: $9.00 inline."}])] == [D("0.50")]),
]
print(";".join("%s=%s" % (n, "ok" if r else "BAD") for n, r in checks))
PY
}
LIB_PROBE="$(ledger_lib_probe)"
case "$LIB_PROBE" in
  *BAD*|"") fail "ledger: library rule probe failed: $LIB_PROBE" ;;
  *) ok "ledger: library sum/allocate/prorate/receipt rules hold ($LIB_PROBE)" ;;
esac

# The real pricing matrix: one well-formed block covering all six tools, every
# figure (rates AND caps) carrying unit, source and retrieved; unknown values
# null, never 0; Greptile's flex cap recorded.
ledger_real_rates_probe() {
  python3 - "$REPO_ROOT/.claude/scripts/lib" "$REPO_ROOT/.claude/reference/pricing-matrix.md" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import review_ledger as L
rates, notes = L.parse_rates(sys.argv[2])
if rates is None:
    print("BAD unreadable: %s" % notes); sys.exit()
figs = list(rates["tools"].values()) + list(rates["caps"])
checks = [
    ("six-tools", sorted(rates["tools"]) == sorted(L.TOOL_KEYS)),
    ("fields", all(f.get("unit") and f.get("source") and f.get("retrieved") for f in figs)),
    ("unknown-is-null", all(f["usd"] is None for f in figs if f.get("basis") == "unknown")),
    ("graphite-null", rates["tools"]["graphite"]["usd"] is None),
    ("only-graphite-noted", [n.split("'")[0] for n in notes] == ["rates: graphite"]),
    ("greptile-flex-100", any(c["key"] == "greptile_flex" and c["usd"] == 100 for c in rates["caps"])),
    ("bugbot-and-cr-caps", {"bugbot", "coderabbit"} <= {c["tool"] for c in rates["caps"]}),
]
print(";".join("%s=%s" % (n, "ok" if r else "BAD") for n, r in checks))
PY
}
REAL_RATES="$(ledger_real_rates_probe)"
case "$REAL_RATES" in
  *BAD*|"") fail "ledger: the real pricing-matrix rates block is malformed: $REAL_RATES" ;;
  *) ok "ledger: the shipped review-stack-rates block parses and is complete ($REAL_RATES)" ;;
esac

# The parser refuses what it cannot trust, whole — never a partial guess.
ledger_bad_rates_probe() {
  python3 - "$REPO_ROOT/.claude/scripts/lib" "$PRICING_FULL" "$TMP_DIR" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import review_ledger as L
good = open(sys.argv[2]).read()
block = good[good.index("```json"):]
def parse(name, text):
    p = "%s/rates-%s.md" % (sys.argv[3], name)
    open(p, "w").write(text)
    return L.parse_rates(p)
cases = {
    "duplicate": parse("dup", good + "\n" + block)[0] is None,
    "missing": parse("missing", "# no block\n")[0] is None,
    "wrong-schema": parse("schema", good.replace("review-stack-rates/v1", "review-stack-rates/v9"))[0] is None,
    "unterminated": parse("open", good[:good.rindex("```")])[0] is None,
    "bad-json": parse("json", good.replace('"as_of"', "as_of"))[0] is None,
    "unreadable": L.parse_rates(sys.argv[3] + "/no-such.md")[0] is None,
    # A block shown inside another fence is an example, not the block.
    "nested-example-ignored": parse("nested", good + "\n````markdown\n" + block + "\n````\n")[0] is not None,
}
# Python's json reads NaN and Infinity; neither is a price.
for bad in ("NaN", "Infinity", "-Infinity"):
    cases["non-finite-%s" % bad] = parse("nf-" + bad, good.replace('"usd": 2.0', '"usd": %s' % bad, 1))[0] is None
# A figure no price could be (a 400-digit int, 1e300) is refused, not a crash
# later when cents() cannot quantize it.
cases["huge-int-refused"] = parse("huge", good.replace('"usd": 2.0', '"usd": ' + "9" * 400, 1))[0] is None
cases["huge-float-refused"] = parse("hugef", good.replace('"usd": 2.0', '"usd": 1e300', 1))[0] is None
# `informational` is a real boolean: the string "false" would silently drop a rate.
cases["informational-string-refused"] = parse("info", good.replace('"informational": true', '"informational": "false"', 1))[0] is None
r, n = parse("unit", good.replace('"unit": "review"', '"unit": "month"'))
cases["wrong-unit-unusable"] = r is not None and r["usd"]["bugbot"] is None and any("bugbot is priced per 'month'" in x for x in n)
# Greptile's credits per review unknown: its spend is null with a note, never
# priced at an assumed one credit.
r, n = parse("no-cpr", good.replace('"credits_per_review": 1', '"credits_per_review": null', 1))
cases["greptile-null-credits-noted"] = r is not None and r["usd"]["greptile"] is None and any("greptile has no `credits_per_review`" in x for x in n)
# An informational flag on a rate-priced tool nulls its spend, and says so.
r, n = parse("info-bugbot", good.replace('"key": "bugbot",', '"key": "bugbot", "informational": true,', 1))
cases["informational-rate-noted"] = r is not None and r["usd"]["bugbot"] is None and any("bugbot is marked informational" in x for x in n)
print(";".join("%s=%s" % (k, "ok" if v else "BAD") for k, v in cases.items()))
PY
}
BAD_RATES="$(ledger_bad_rates_probe)"
case "$BAD_RATES" in
  *BAD*|"") fail "ledger: parse_rates accepted a block it should refuse: $BAD_RATES" ;;
  *) ok "ledger: parse_rates refuses duplicate/missing/wrong-schema/unterminated/malformed blocks ($BAD_RATES)" ;;
esac

# The library is reached ONLY in ledger mode: a copy of measure.sh with no
# review_ledger.py anywhere still measures without --ledger, and fails closed
# (exit 1, nothing on stdout) with it.
ISO="$TMP_DIR/iso/.claude/skills/review-stack-audit"
mkdir -p "$ISO"
cp "$MEASURE" "$ISO/measure.sh"
( cd "$TMP_DIR" && "$ISO/measure.sh" --fixture "$LEDGER_F" --json > "$TMP_DIR/iso-legacy.out" 2>/dev/null )
rc_legacy=$?
( cd "$TMP_DIR" && "$ISO/measure.sh" --fixture "$LEDGER_F" --ledger --json > "$TMP_DIR/iso-ledger.out" 2>"$TMP_DIR/iso-ledger.err" )
rc_ledger=$?
if [[ $rc_legacy -eq 0 && -s "$TMP_DIR/iso-legacy.out" && $rc_ledger -eq 1 && ! -s "$TMP_DIR/iso-ledger.out" ]] \
   && grep -q 'review_ledger.py not found' "$TMP_DIR/iso-ledger.err"; then
  ok "ledger: without the library the legacy path still runs and ledger mode fails closed"
else
  fail "ledger: library isolation wrong (legacy rc=$rc_legacy, ledger rc=$rc_ledger)"
fi

[[ $FAILED -eq 0 ]] && echo "All review-stack-audit tests passed."
exit $FAILED
