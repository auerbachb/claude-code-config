#!/usr/bin/env bash
# Offline tests for review-daily-cap.sh — the account-level daily soft cap on
# paid reviewer triggers (issue #1812).
# catalog: tests — Tests `review-daily-cap.sh` offline — cap resolution (env, account config, default, unparseable values), the ET-day boundary, null rates, the fail-open `unknown`, the live adapter against a stubbed gh (comments read from both ends, BugBot read limits noted), and the 5-minute cache
#
# WHAT IS UNDER TEST
#   Fixture mode runs the REAL script against review_ledger.py's normalized
#   extraction shape, so the arithmetic, the ET boundary, and the status rules
#   are the shipped ones. Live mode runs a copy of the script beside a stubbed
#   review-repos.sh, with a gh stub on PATH that serves GraphQL pages from
#   files and counts its calls — so the GraphQL normalization, pagination, the
#   fail-open paths, and the cache are exercised without the network.
#
#   Every "unknown" case also asserts spent_usd is null: an unreadable tally
#   that printed 0 would read as "nothing spent", which is the failure the
#   status exists to prevent.

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SCRIPT="$REPO_ROOT/.claude/scripts/review-daily-cap.sh"
TMP="$(mktemp -d)"
TMP_HOME="$(mktemp -d)"
cleanup() { chmod -R u+rw "$TMP" 2>/dev/null; rm -rf "$TMP" "$TMP_HOME"; }
trap cleanup EXIT
export HOME="$TMP_HOME"
mkdir -p "$HOME/.claude"
export CLAUDE_ACCOUNT_CONFIG="$TMP/account-config.md"
unset REVIEW_DAILY_CAP_USD_BUGBOT REVIEW_DAILY_CAP_USD_CODERABBIT REVIEW_DAILY_CAP_USD_GREPTILE
unset REVIEW_RATE_USD_BUGBOT REVIEW_RATE_USD_CODERABBIT REVIEW_RATE_USD_GREPTILE REVIEW_REPOS

if ! command -v jq >/dev/null 2>&1 || ! command -v python3 >/dev/null 2>&1; then
  echo "SKIP: review-daily-cap tests need jq and python3"
  exit 0
fi

PASS=0
FAIL=0
check_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$actual" == "$expected" ]]; then
    PASS=$((PASS + 1)); echo "ok   — $desc"
  else
    FAIL=$((FAIL + 1)); echo "FAIL — $desc (expected '$expected', got '$actual')"
  fi
}
check_contains() {
  local desc="$1" needle="$2" hay="$3"
  if [[ "$hay" == *"$needle"* ]]; then
    PASS=$((PASS + 1)); echo "ok   — $desc"
  else
    FAIL=$((FAIL + 1)); echo "FAIL — $desc (no '$needle' in: ${hay:0:300})"
  fi
}

OUT=""; ERR=""; RC=0
run() {   # run the script under test with "$@"; sets OUT, ERR, RC
  local errf="$TMP/err"
  RC=0
  # From $TMP, so the script's cwd-relative fallback (.claude/scripts/...)
  # can never find this checkout's real helpers behind a stub's back.
  OUT="$(cd "$TMP" && "${RUN_SCRIPT:-$SCRIPT}" "$@" 2>"$errf")" || RC=$?
  ERR="$(cat "$errf")"
}
field() { jq -r ".$1" <<<"$OUT"; }

# 11:00 ET on 2026-10-08 (EDT, UTC-4).
export REVIEW_DAILY_CAP_NOW="2026-10-08T15:00:00Z"

run_obj() { printf '{"id": %s, "name": "Cursor Bugbot", "app": "cursor", "started_at": "%s"}' "$1" "$2"; }

# Two repos, three billable runs today ET ($4.74 at $1.58). Decoys: a run at
# 03:00Z (23:00 ET on the 7th), a duplicate id, and a run from another app.
cat > "$TMP/two-repo.json" <<EOF
{"repos": [
  {"repo": "acme/one", "prs": [{"number": 1, "check_runs": [
      $(run_obj 11 2026-10-08T13:00:00Z), $(run_obj 12 2026-10-08T14:00:00Z),
      $(run_obj 13 2026-10-08T03:00:00Z)]}]},
  {"repo": "acme/two", "prs": [{"number": 7, "check_runs": [
      $(run_obj 21 2026-10-08T12:30:00Z), $(run_obj 21 2026-10-08T12:30:00Z),
      {"id": 22, "name": "Cursor Bugbot", "app": "someone-else", "started_at": "2026-10-08T12:30:00Z"}]}]}
]}
EOF

rates_doc() {   # <bugbot usd JSON value>
  cat <<EOF
{"schema": "review-stack-rates/v1", "as_of": "2026-10-08",
 "tools": [{"key": "bugbot", "usd": $1, "unit": "review", "basis": "observed_average",
            "source": "test", "retrieved": "2026-10-08"},
           {"key": "greptile", "usd": 0.5, "unit": "credit", "credits_per_review": 2,
            "source": "test", "retrieved": "2026-10-08"}]}
EOF
}

############################################################################
echo "== test plan 1: two repos at \$4.74, cap 5, +1.58 -> over; default cap -> ok =="
REVIEW_DAILY_CAP_USD_BUGBOT=5 run bugbot --add-usd 1.58 --fixture "$TMP/two-repo.json"
check_eq "cap 5: exit 1" "1" "$RC"
check_eq "cap 5: status over" "over" "$(field status)"
check_eq "cap 5: spent is the three runs today (4.74)" "4.74" "$(field spent_usd)"
check_eq "cap 5: cap_usd 5" "5" "$(field cap_usd)"
check_eq "cap 5: add_usd 1.58" "1.58" "$(field add_usd)"
check_eq "cap 5: date is the ET date" "2026-10-08" "$(field date)"
check_eq "exactly the six documented keys, in order" '["platform","date","spent_usd","add_usd","cap_usd","status"]' \
  "$(jq -c 'keys_unsorted' <<<"$OUT")"
check_eq "one line of output" "1" "$(printf '%s\n' "$OUT" | grep -c .)"
run bugbot --add-usd 1.58 --fixture "$TMP/two-repo.json"
check_eq "cap unset: exit 0" "0" "$RC"
check_eq "cap unset: status ok" "ok" "$(field status)"
check_eq "cap unset: default cap 10" "10" "$(field cap_usd)"

echo "== the comparison is strict: spent + add == cap is ok =="
REVIEW_DAILY_CAP_USD_BUGBOT=6.32 run bugbot --add-usd 1.58 --fixture "$TMP/two-repo.json"
check_eq "4.74 + 1.58 == 6.32 -> ok" "ok" "$(field status)"
check_eq "  exit 0" "0" "$RC"
REVIEW_DAILY_CAP_USD_BUGBOT=6.31 run bugbot --add-usd 1.58 --fixture "$TMP/two-repo.json"
check_eq "4.74 + 1.58 > 6.31 -> over" "over" "$(field status)"
REVIEW_DAILY_CAP_USD_BUGBOT=4.74 run bugbot --fixture "$TMP/two-repo.json"
check_eq "no --add-usd: add 0, spent == cap -> ok" "ok" "$(field status)"
check_eq "  add_usd 0" "0" "$(field add_usd)"

############################################################################
echo "== test plan 2: a null BugBot rate -> unknown, exit 0, spent null =="
{ printf '{"rates": '; rates_doc null; printf ', "repos": '; jq -c '.repos' "$TMP/two-repo.json"; printf '}'; } > "$TMP/null-rate.json"
REVIEW_DAILY_CAP_USD_BUGBOT=5 run bugbot --add-usd 1.58 --fixture "$TMP/null-rate.json"
check_eq "null rate: exit 0" "0" "$RC"
check_eq "null rate: status unknown" "unknown" "$(field status)"
check_eq "null rate: spent_usd null, never 0" "null" "$(field spent_usd)"
check_contains "null rate: stderr says why" "rate is null" "$ERR"
check_contains "null rate: stderr names the rates note" "bugbot's per-review rate is null" "$ERR"
echo "== a fixture rate is used instead of the pricing file =="
{ printf '{"rates": '; rates_doc 2.0; printf ', "repos": '; jq -c '.repos' "$TMP/two-repo.json"; printf '}'; } > "$TMP/rate-2.json"
run bugbot --fixture "$TMP/rate-2.json"
check_eq "three runs at \$2.00 = 6.00" "6" "$(field spent_usd)"

############################################################################
echo "== test plan 3: spend dated yesterday ET only -> spent 0, ok =="
cat > "$TMP/yesterday.json" <<EOF
{"repos": [{"repo": "acme/one", "prs": [{"number": 1, "check_runs": [
   $(run_obj 31 2026-10-08T03:30:00Z), $(run_obj 32 2026-10-07T20:00:00Z)]}]}]}
EOF
run bugbot --add-usd 1.58 --fixture "$TMP/yesterday.json"
check_eq "03:30Z on the 8th is the 7th in ET: spent 0" "0" "$(field spent_usd)"
check_eq "  status ok" "ok" "$(field status)"
check_eq "  exit 0" "0" "$RC"
check_eq "  date is today ET" "2026-10-08" "$(field date)"
echo "== the same run, seen from 23:45 ET on the 7th, IS that day's spend =="
REVIEW_DAILY_CAP_NOW="2026-10-08T03:45:00Z" run bugbot --fixture "$TMP/yesterday.json"
check_eq "date is the ET date (the UTC date is the 8th)" "2026-10-07" "$(field date)"
check_eq "both runs count on the 7th ET" "3.16" "$(field spent_usd)"
echo "== winter (EST, UTC-5): ET midnight is 05:00Z =="
cat > "$TMP/winter.json" <<EOF
{"repos": [{"repo": "acme/one", "prs": [{"number": 1, "check_runs": [
   $(run_obj 41 2026-12-02T04:30:00Z), $(run_obj 42 2026-12-02T05:30:00Z)]}]}]}
EOF
REVIEW_DAILY_CAP_NOW="2026-12-02T15:00:00Z" run bugbot --fixture "$TMP/winter.json"
check_eq "04:30Z is the 1st in EST; only 05:30Z counts" "1.58" "$(field spent_usd)"
check_eq "  date 2026-12-02" "2026-12-02" "$(field date)"
echo "== epoch-second clocks are accepted =="
REVIEW_DAILY_CAP_NOW="1791471600" run bugbot --fixture "$TMP/two-repo.json"
check_eq "epoch 1791471600 is 2026-10-08 ET" "2026-10-08" "$(field date)"

############################################################################
echo "== the cap from the account config =="
write_config() { printf '%s\n' "# Account Config" "" "## Review repos" "" "- acme/one" "" "## Review daily caps" "" "$@" > "$CLAUDE_ACCOUNT_CONFIG"; }
write_config '```ini' 'REVIEW_DAILY_CAP_USD_BUGBOT = 5' 'REVIEW_DAILY_CAP_USD_CODERABBIT = 7' '```'
run bugbot --add-usd 1.58 --fixture "$TMP/two-repo.json"
check_eq "config cap 5 -> over" "over" "$(field status)"
check_eq "  cap_usd 5" "5" "$(field cap_usd)"
check_eq "  no warning" "" "$ERR"
REVIEW_DAILY_CAP_USD_BUGBOT=10 run bugbot --add-usd 1.58 --fixture "$TMP/two-repo.json"
check_eq "env beats the config" "10" "$(field cap_usd)"
REVIEW_DAILY_CAP_USD_BUGBOT="" run bugbot --add-usd 1.58 --fixture "$TMP/two-repo.json"
check_eq "a blank env counts as unset (config wins)" "5" "$(field cap_usd)"
write_config '<!-- REVIEW_DAILY_CAP_USD_BUGBOT = 1 is an example, not a setting -->' \
  'review_daily_cap_usd_bugbot: 7.5   # lower-case key, colon, inline note' 'REVIEW_DAILY_CAP_USD_BUGBOT = 2'
run bugbot --fixture "$TMP/two-repo.json"
check_eq "HTML comment ignored; any case; ':'; first match; note dropped" "7.5" "$(field cap_usd)"
write_config 'REVIEW_DAILY_CAP_USD_CODERABBIT = 3'
run bugbot --fixture "$TMP/two-repo.json"
check_eq "no key for this platform -> default" "10" "$(field cap_usd)"
check_eq "  silently" "" "$ERR"
printf '# Account Config\n\n## Review repos\n\n- acme/one\n' > "$CLAUDE_ACCOUNT_CONFIG"
run bugbot --fixture "$TMP/two-repo.json"
check_eq "no section -> default, silently" "10|" "$(field cap_usd)|$ERR"
rm -f "$CLAUDE_ACCOUNT_CONFIG"
run bugbot --fixture "$TMP/two-repo.json"
check_eq "no config file -> default, silently" "10|" "$(field cap_usd)|$ERR"

echo "== unparseable values warn and fall back to the default =="
REVIEW_DAILY_CAP_USD_BUGBOT='$5' run bugbot --add-usd 1.58 --fixture "$TMP/two-repo.json"
check_eq "env '\$5' -> default 10" "10" "$(field cap_usd)"
check_contains "  warns, naming the key" "REVIEW_DAILY_CAP_USD_BUGBOT='\$5' (env) is not a non-negative decimal" "$ERR"
write_config 'REVIEW_DAILY_CAP_USD_BUGBOT = ten'
run bugbot --fixture "$TMP/two-repo.json"
check_eq "config 'ten' -> default 10" "10" "$(field cap_usd)"
check_contains "  warns" "(account config) is not a non-negative decimal" "$ERR"
write_config 'REVIEW_DAILY_CAP_USD_BUGBOT = -1'
run bugbot --fixture "$TMP/two-repo.json"
check_eq "config '-1' -> default 10" "10" "$(field cap_usd)"
write_config 'REVIEW_DAILY_CAP_USD_BUGBOT = 0'
run bugbot --add-usd 1.58 --fixture "$TMP/two-repo.json"
check_eq "a cap of 0 is valid (every paid trigger skips)" "0|over" "$(field cap_usd)|$(field status)"
if [[ "$(id -u)" -ne 0 ]]; then
  write_config 'REVIEW_DAILY_CAP_USD_BUGBOT = 5'
  chmod 000 "$CLAUDE_ACCOUNT_CONFIG"
  run bugbot --fixture "$TMP/two-repo.json"
  chmod 644 "$CLAUDE_ACCOUNT_CONFIG"
  check_eq "unreadable config -> default 10" "10" "$(field cap_usd)"
  check_contains "  warns" "account config is not a readable file" "$ERR"
else
  echo "skip — running as root, chmod 000 cannot make the config unreadable"
fi
rm -f "$CLAUDE_ACCOUNT_CONFIG"

############################################################################
echo "== other platforms =="
cat > "$TMP/cr.json" <<'EOF'
{"repos": [{"repo": "acme/one", "prs": [{"number": 3, "issue_comments": [
  {"user": "coderabbitai[bot]", "body": "summary\n- Charged: $3.25\n", "created_at": "2026-10-07T10:00:00Z", "updated_at": "2026-10-08T14:00:00Z"},
  {"user": "coderabbitai[bot]", "body": "- Charged: $9.00", "created_at": "2026-10-07T10:00:00Z", "updated_at": "2026-10-07T23:00:00Z"},
  {"user": "auerbachb", "body": "- Charged: $50.00", "created_at": "2026-10-08T14:00:00Z"}]}]},
 {"repo": "acme/two", "prs": [{"number": 4, "issue_comments": [
  {"user": "coderabbitai[bot]", "body": "**Charged:** $1.50", "created_at": "2026-10-08T12:00:00Z"},
  {"user": "auerbachb", "body": "@greptileai", "created_at": "2026-10-08T12:00:00Z"},
  {"user": "auerbachb", "body": "@greptileai please", "created_at": "2026-10-08T13:00:00Z"},
  {"user": "greptile-apps[bot]", "body": "@greptileai footer", "created_at": "2026-10-08T13:00:00Z"}]}]}],
 "rates": RATES}
EOF
python3 - "$TMP/cr.json" "$(rates_doc 1.58)" <<'PY'
import sys
p = sys.argv[1]
text = open(p).read()
open(p, "w").write(text.replace("RATES", sys.argv[2]))
PY
REVIEW_DAILY_CAP_USD_CODERABBIT=4 run coderabbit --fixture "$TMP/cr.json"
check_eq "coderabbit: today's bot receipts across both repos (3.25 + 1.50)" "4.75" "$(field spent_usd)"
check_eq "  over a cap of 4" "over|1" "$(field status)|$RC"
run greptile --fixture "$TMP/cr.json"
check_eq "greptile: 2 human triggers x 2 credits x \$0.50" "2" "$(field spent_usd)"
run greptile --rate --fixture "$TMP/cr.json"
check_eq "greptile --rate: \$/credit x credits/review" "1.00" "$OUT"

############################################################################
echo "== --rate =="
run bugbot --rate --fixture "$TMP/rate-2.json"
check_eq "the block's rate wins" "2.00|0" "$OUT|$RC"
run bugbot --rate
check_eq "the shipped pricing-matrix.md rate" "1.58" "$OUT"
run bugbot --rate --fixture "$TMP/null-rate.json"
check_eq "a null rate falls back to the documented 1.58" "1.58" "$OUT"
check_contains "  and says so" "using the fallback" "$ERR"
REVIEW_RATE_USD_BUGBOT=2.10 run bugbot --rate --fixture "$TMP/null-rate.json"
check_eq "REVIEW_RATE_USD_BUGBOT overrides the fallback" "2.10" "$OUT"
REVIEW_RATE_USD_BUGBOT=2.10 run bugbot --rate --fixture "$TMP/rate-2.json"
check_eq "  but never a usable block rate" "2.00" "$OUT"
run coderabbit --rate
check_eq "coderabbit has no per-review rate: 0" "0|0" "$OUT|$RC"

############################################################################
echo "== usage errors exit 2 =="
run; check_eq "no platform" "2" "$RC"
run copilot; check_eq "unknown platform" "2" "$RC"
run bugbot --add-usd abc; check_eq "malformed --add-usd" "2" "$RC"
run bugbot --add-usd -1; check_eq "negative --add-usd" "2" "$RC"
run bugbot --fixture "$TMP/missing.json"; check_eq "missing fixture" "2" "$RC"
run bugbot --rate --add-usd 1; check_eq "--rate with --add-usd" "2" "$RC"
run bugbot --bogus; check_eq "unknown flag" "2" "$RC"
printf 'not json' > "$TMP/bad.json"
run bugbot --fixture "$TMP/bad.json"; check_eq "malformed fixture" "2" "$RC"
printf '{"prs": []}' > "$TMP/norepos.json"
run bugbot --fixture "$TMP/norepos.json"; check_eq "fixture without a repos array" "2" "$RC"
REVIEW_DAILY_CAP_NOW="yesterday" run bugbot --fixture "$TMP/two-repo.json"; check_eq "bad clock" "2" "$RC"
run --help
check_eq "--help exits 0" "0" "$RC"
check_contains "--help prints the usage" "review-daily-cap.sh <platform> [--add-usd X] [--fixture <path>]" "$OUT"
echo "== an empty repo list is unknown, never 0 =="
printf '{"repos": []}' > "$TMP/empty.json"
run bugbot --fixture "$TMP/empty.json"
check_eq "empty fixture: unknown, spent null, exit 0" "unknown|null|0" "$(field status)|$(field spent_usd)|$RC"

############################################################################
# Live mode: a copy of the script beside a stubbed review-repos.sh, with the
# real ledger and pricing file, and gh stubbed on PATH.
STUB="$TMP/live/.claude"
mkdir -p "$STUB/scripts/lib" "$STUB/reference"
cp "$SCRIPT" "$STUB/scripts/"
cp "$REPO_ROOT/.claude/scripts/lib/review_ledger.py" "$STUB/scripts/lib/"
cp "$REPO_ROOT/.claude/reference/pricing-matrix.md" "$STUB/reference/"
cat > "$STUB/scripts/review-repos.sh" <<'EOF'
#!/usr/bin/env bash
[[ -n "${STUB_REPOS_RC:-}" ]] && exit "$STUB_REPOS_RC"
printf '%s' "${STUB_REPOS-acme/one
acme/two
}"
EOF
chmod +x "$STUB/scripts/review-daily-cap.sh" "$STUB/scripts/review-repos.sh"
RUN_SCRIPT="$STUB/scripts/review-daily-cap.sh"

GH_DIR="$TMP/gh"
mkdir -p "$GH_DIR" "$TMP/bin"
export GH_DIR GH_CALLS="$TMP/gh-calls"
cat > "$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
# Serves `gh api graphql ... -f name=<repo> [-f endCursor=<c>]` from
# $GH_DIR/<repo>[-<c>].json, and logs one line per call.
name="" cursor="" prev=""
for a in "$@"; do
  if [[ "$prev" == "-f" ]]; then
    case "$a" in name=*) name="${a#name=}" ;; endCursor=*) cursor="${a#endCursor=}" ;; esac
  fi
  prev="$a"
done
echo "$name ${cursor:-first}" >> "$GH_CALLS"
[[ -e "$GH_DIR/fail" ]] && { echo "HTTP 502: bad gateway" >&2; exit 1; }
f="$GH_DIR/$name${cursor:+-$cursor}.json"
[[ -f "$f" ]] || { echo "no stub for $f" >&2; exit 1; }
cat "$f"
EOF
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH"

pr_node() {   # <number> <updatedAt> <run id> <run startedAt>
  printf '{"number": %s, "updatedAt": "%s", "commits": {"totalCount": 1, "nodes": [{"commit": {"checkSuites": {"nodes": [{"app": {"slug": "cursor"}, "checkRuns": {"nodes": [{"databaseId": %s, "name": "Cursor Bugbot", "startedAt": "%s"}]}}]}}}]}}' "$@"
}
page() {   # <hasNextPage> <endCursor> <node>...
  local next="$1" cursor="$2"; shift 2
  local IFS=,
  printf '{"data": {"repository": {"pullRequests": {"pageInfo": {"hasNextPage": %s, "endCursor": "%s"}, "nodes": [%s]}}}}' "$next" "$cursor" "$*"
}
# acme/one: two pages. Page 1: two PRs updated today. Page 2: one more today,
# then one updated yesterday ET — paging stops there, so page 3 is never asked.
page true c1 "$(pr_node 5 2026-10-08T14:50:00Z 501 2026-10-08T14:40:00Z)" \
             "$(pr_node 4 2026-10-08T14:00:00Z 401 2026-10-08T13:00:00Z)" > "$GH_DIR/one.json"
page true c2 "$(pr_node 3 2026-10-08T05:00:00Z 301 2026-10-08T04:30:00Z)" \
             "$(pr_node 2 2026-10-08T03:00:00Z 201 2026-10-08T03:00:00Z)" > "$GH_DIR/one-c1.json"
# acme/two: one page, one PR today with a run today and a run before ET midnight.
page false "" "$(pr_node 9 2026-10-08T12:00:00Z 901 2026-10-08T11:00:00Z)" > "$GH_DIR/two.json"
python3 - "$GH_DIR/two.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
node = d["data"]["repository"]["pullRequests"]["nodes"][0]
suite = node["commits"]["nodes"][0]["commit"]["checkSuites"]["nodes"][0]
suite["checkRuns"]["nodes"].append({"databaseId": 902, "name": "Cursor Bugbot", "startedAt": "2026-10-08T02:00:00Z"})
json.dump(d, open(p, "w"))
PY
calls() { wc -l < "$GH_CALLS" | tr -d ' '; }

echo "== live: two registered repos, paged until a PR older than ET midnight =="
: > "$GH_CALLS"
run bugbot --add-usd 1.58
check_eq "live: ok, exit 0" "ok|0" "$(field status)|$RC"
check_eq "live: runs 501, 401, 301 (one) + 901 (two) = 4 x 1.58" "6.32" "$(field spent_usd)"
check_eq "live: one page for two, two for one" "one first;one c1;two first;" "$(tr '\n' ';' < "$GH_CALLS")"
check_eq "live: the tally was cached" "6.32" "$(jq -r '.spent_usd' "$HOME/.claude/review-daily-cap/bugbot-2026-10-08.json")"

echo "== cache: a second call within 5 minutes reads no GitHub =="
page false "" "$(pr_node 9 2026-10-08T12:00:00Z 999 2026-10-08T12:00:00Z)" "$(pr_node 8 2026-10-08T12:00:00Z 998 2026-10-08T12:00:00Z)" > "$GH_DIR/two.json"
REVIEW_DAILY_CAP_NOW="2026-10-08T15:04:00Z" REVIEW_DAILY_CAP_USD_BUGBOT=7 run bugbot --add-usd 1.58
check_eq "cache hit: no gh calls" "3" "$(calls)"
check_eq "cache hit: the cached spend" "6.32" "$(field spent_usd)"
check_eq "cache hit: the CURRENT cap applies (7 -> over)" "over|7" "$(field status)|$(field cap_usd)"
echo "== cache: after 5 minutes it reads GitHub again =="
REVIEW_DAILY_CAP_NOW="2026-10-08T15:05:01Z" run bugbot --add-usd 1.58
check_eq "expired: three more gh calls" "6" "$(calls)"
check_eq "expired: the fresh spend (one: 3 runs, two: 2 runs)" "7.9" "$(field spent_usd)"
echo "== cache: a new ET day never reads yesterday's entry =="
: > "$GH_CALLS"
REVIEW_DAILY_CAP_NOW="2026-10-09T04:01:00Z" run bugbot
check_eq "00:01 ET on the 9th: GitHub is read (one page per repo, all older)" "2" "$(calls)"
check_eq "  dated the 9th, nothing spent yet" "2026-10-09|0" "$(field date)|$(field spent_usd)"

echo "== live fail-open: gh fails -> unknown, null, exit 0, not cached =="
rm -rf "$HOME/.claude/review-daily-cap"
touch "$GH_DIR/fail"; : > "$GH_CALLS"
run bugbot --add-usd 1.58
check_eq "gh failure: unknown|null|0" "unknown|null|0" "$(field status)|$(field spent_usd)|$RC"
check_contains "  stderr names the failure" "gh api graphql failed" "$ERR"
check_eq "  nothing cached" "no" "$( [[ -e "$HOME/.claude/review-daily-cap/bugbot-2026-10-08.json" ]] && echo yes || echo no )"
run bugbot --add-usd 1.58
check_eq "  so the next call asks GitHub again" "2" "$(calls)"
rm -f "$GH_DIR/fail"

echo "== live fail-open: GraphQL errors -> unknown =="
printf '{"errors": [{"message": "Something went wrong"}]}' > "$GH_DIR/two.json"
run bugbot
check_eq "graphql errors: unknown|null" "unknown|null" "$(field status)|$(field spent_usd)"
check_contains "  stderr says so" "returned errors" "$ERR"
printf 'not json' > "$GH_DIR/two.json"
run bugbot
check_eq "unparseable gh output: unknown" "unknown" "$(field status)"

echo "== live fail-open: the registry =="
STUB_REPOS_RC=1 run bugbot
check_eq "review-repos.sh fails: unknown|null|0" "unknown|null|0" "$(field status)|$(field spent_usd)|$RC"
STUB_REPOS="" run bugbot
check_eq "review-repos.sh lists nothing: unknown" "unknown|null" "$(field status)|$(field spent_usd)"
check_contains "  stderr says so" "listed no repos" "$ERR"
mv "$STUB/scripts/review-repos.sh" "$TMP/rr.bak"
run bugbot
mv "$TMP/rr.bak" "$STUB/scripts/review-repos.sh"
check_eq "review-repos.sh missing: unknown" "unknown" "$(field status)"

echo "== live: CodeRabbit receipts from GraphQL comments (bot logins gain [bot]) =="
# A short PR: both ends of the comment read return the same two comments.
CR_NODES='[{"id": "IC_1", "author": {"__typename": "Bot", "login": "coderabbitai"}, "body": "- Charged: $2.25", "createdAt": "2026-10-08T13:00:00Z", "updatedAt": "2026-10-08T13:30:00Z"}, {"id": "IC_2", "author": {"__typename": "User", "login": "coderabbitai"}, "body": "- Charged: $40.00", "createdAt": "2026-10-08T13:00:00Z", "updatedAt": "2026-10-08T13:00:00Z"}]'
printf '{"data": {"repository": {"pullRequests": {"pageInfo": {"hasNextPage": false, "endCursor": null}, "nodes": [{"number": 5, "updatedAt": "2026-10-08T14:00:00Z", "oldest": {"totalCount": 2, "nodes": %s}, "newest": {"nodes": %s}}]}}}}' "$CR_NODES" "$CR_NODES" > "$GH_DIR/one.json"
STUB_REPOS="acme/one" run coderabbit
check_eq "only the Bot-authored receipt counts, once though read from both ends" "2.25|ok" "$(field spent_usd)|$(field status)"

echo "== live: a PR past 200 comments — the summary is oldest, today's triggers newest =="
rm -rf "$HOME/.claude/review-daily-cap"
OLDEST='{"totalCount": 250, "nodes": [{"id": "IC_10", "author": {"__typename": "Bot", "login": "coderabbitai"}, "body": "- Charged: $1.75", "createdAt": "2026-09-01T10:00:00Z", "updatedAt": "2026-10-08T12:00:00Z"}]}'
NEWEST='{"nodes": [{"id": "IC_240", "author": {"__typename": "User", "login": "auerbachb"}, "body": "@greptileai", "createdAt": "2026-10-08T03:00:00Z", "updatedAt": "2026-10-08T03:00:00Z"}, {"id": "IC_249", "author": {"__typename": "User", "login": "auerbachb"}, "body": "@greptileai", "createdAt": "2026-10-08T12:00:00Z", "updatedAt": "2026-10-08T12:00:00Z"}, {"id": "IC_250", "author": {"__typename": "User", "login": "auerbachb"}, "body": "@greptileai again", "createdAt": "2026-10-08T14:00:00Z", "updatedAt": "2026-10-08T14:00:00Z"}]}'
printf '{"data": {"repository": {"pullRequests": {"pageInfo": {"hasNextPage": false, "endCursor": null}, "nodes": [{"number": 7, "updatedAt": "2026-10-08T14:00:00Z", "oldest": %s, "newest": %s}]}}}}' "$OLDEST" "$NEWEST" > "$GH_DIR/one.json"
STUB_REPOS="acme/one" run greptile --rate
GREPTILE_RATE="$OUT"
STUB_REPOS="acme/one" run greptile
check_eq "greptile: the two triggers made today (03:00Z is the 7th ET) are read from the newest end" \
  "2 x $GREPTILE_RATE|ok" \
  "$(python3 -c 'import sys; from decimal import Decimal as D; r, s = D(sys.argv[1]), D(sys.argv[2]); print("2 x %s" % sys.argv[1] if s == 2 * r else "%s, not 2 x %s" % (s, r))' "$GREPTILE_RATE" "$(field spent_usd)")|$(field status)"
check_contains "  stderr says the middle was skipped" "only its first 100 and last 100 of 250 comments" "$ERR"
STUB_REPOS="acme/one" run coderabbit
check_eq "coderabbit: the receipt edited today is read from the oldest end" "1.75|ok" "$(field spent_usd)|$(field status)"

echo "== live: BugBot suites and runs past the read limit are noted, not dropped silently =="
rm -rf "$HOME/.claude/review-daily-cap"
page false "" "$(pr_node 6 2026-10-08T14:00:00Z 601 2026-10-08T13:00:00Z)" > "$GH_DIR/one.json"
python3 - "$GH_DIR/one.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
commit = d["data"]["repository"]["pullRequests"]["nodes"][0]["commits"]["nodes"][0]["commit"]
commit["oid"] = "abcdef0123456789"
commit["checkSuites"]["totalCount"] = 6
commit["checkSuites"]["nodes"][0]["checkRuns"]["totalCount"] = 25
json.dump(d, open(p, "w"))
PY
STUB_REPOS="acme/one" run bugbot
check_eq "the runs that were read still count" "1.58|ok" "$(field spent_usd)|$(field status)"
check_contains "  stderr names the suite overflow" "only 5 of 6 BugBot check suites on abcdef0" "$ERR"
check_contains "  stderr names the run overflow" "only 20 of 25 BugBot check-runs in one suite on abcdef0" "$ERR"

echo "== missing ledger library -> unknown (and --rate still answers) =="
mv "$STUB/scripts/lib/review_ledger.py" "$TMP/ledger.bak"
run bugbot --add-usd 1.58 --fixture "$TMP/two-repo.json"
check_eq "no ledger: unknown|null|0" "unknown|null|0" "$(field status)|$(field spent_usd)|$RC"
check_contains "  stderr names it" "review_ledger.py not found" "$ERR"
run bugbot --rate
check_eq "no ledger: --rate falls back to 1.58" "1.58" "$OUT"
mv "$TMP/ledger.bak" "$STUB/scripts/lib/review_ledger.py"

echo
echo "== summary: $PASS passed, $FAIL failed =="
[[ "$FAIL" -eq 0 ]] || exit 1
echo "OK: review-daily-cap.sh tests passed"
