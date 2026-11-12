#!/usr/bin/env bash
# maybe-trigger-reviewer-choice.test.sh — offline fixture tests for the free-reviewer choice of the AI review request (issue #2257), through the REAL maybe-trigger-ai-review.sh (legacy path, after-ci). Harness copied from maybe-trigger-tier-triggers.test.sh (see its header for the stubs).
# catalog: tests — Tests the free-reviewer choice of `maybe-trigger-ai-review.sh` (issue #2257) — CodeAnt or CodeRabbit by earliest answer, CodeRabbit limited or budget spent, both limited skip, alternation across PRs, exact anchor body, recorded choice
#
# WHAT IS UNDER TEST
#   With a `## Review policy`, every post goes through the shared
#   review-triggers-allowed.sh: allowed steps are claimed, then posted;
#   excluded steps are skipped for good; deferred steps leave the step record
#   open so the next poll tick asks again. Without a policy the script's legacy
#   path runs exactly as before — proven here with the helper PRESENT.
#
# HOW IT IS OBSERVED
#   The REAL maybe-trigger-ai-review.sh, review-triggers-allowed.sh,
#   bugbot-tier-excluded.sh, ci-status.sh, check-runs-dedup.sh and
#   session-state.sh run from a stub script dir. Stubbed: review-tier.sh, the
#   round/complexity gates, bugbot-refused-head.sh, review-daily-cap.sh, and
#   `gh`, which appends each posted comment to $POSTED and — like GitHub —
#   to the PR's comment list, so later runs count it.

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
TMP="$(mktemp -d)"
TMP_HOME="$(mktemp -d)"
cleanup() { rm -rf "$TMP" "$TMP_HOME"; }
trap cleanup EXIT
export HOME="$TMP_HOME"
mkdir -p "$HOME/.claude"

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

PR=99600
HEAD="cccccccccccccccccccccccccccccccccccccccc"
HEAD2="dddddddddddddddddddddddddddddddddddddddd"

S="$TMP/scripts"
mkdir -p "$S/lib" "$TMP/reference"
for f in maybe-trigger-ai-review.sh review-triggers-allowed.sh bugbot-tier-excluded.sh ci-status.sh \
         check-runs-dedup.sh session-state.sh state-lock.sh review-request-gate.sh \
         review-availability.sh pr-authorship.sh cr-review-hourly.sh; do
  cp "$REPO_ROOT/.claude/scripts/$f" "$S/"
done
cp "$REPO_ROOT/.claude/scripts/lib/repo-normalizer.sh" "$REPO_ROOT/.claude/scripts/lib/ts-normalizer.sh" \
   "$REPO_ROOT/.claude/scripts/lib/codeant-round.jq" "$REPO_ROOT/.claude/scripts/lib/check-run-conclusions.jq" \
   "$REPO_ROOT/.claude/scripts/lib/cr-retry-window.jq" "$S/lib/"
cp "$REPO_ROOT/.claude/reference/session-state-schema.json" "$TMP/reference/"
cat > "$S/review-tier.sh" <<'EOF'
#!/usr/bin/env bash
[[ -n "${FIXTURE_TIER_OUT:-}" ]] && printf '%s\n' "$FIXTURE_TIER_OUT"
exit "${FIXTURE_TIER_RC:-0}"
EOF
cat > "$S/bugbot-refused-head.sh" <<'EOF'
#!/usr/bin/env bash
[[ -n "${FIXTURE_REFUSED:-}" ]]
EOF
cat > "$S/review-daily-cap.sh" <<'EOF'
#!/usr/bin/env bash
if [[ " $* " == *" --rate "* ]]; then echo 1.58; exit 0; fi
# FIXTURE_CAP_FLIP=<counter file>: the first tally is ok, every later one over.
if [[ -n "${FIXTURE_CAP_FLIP:-}" ]]; then
  n=$(( $(cat "$FIXTURE_CAP_FLIP" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$FIXTURE_CAP_FLIP"
  if (( n > 1 )); then printf '%s\n' "$FIXTURE_CAP_OVER"; exit 1; fi
fi
printf '%s\n' "$FIXTURE_CAP_OUT"
exit "${FIXTURE_CAP_RC:-0}"
EOF
printf '#!/usr/bin/env bash\necho "${FIXTURE_ROUNDS:-3}"\n' > "$S/cycle-count.sh"
printf '#!/usr/bin/env bash\necho "${FIXTURE_SCORE:-500}"\n' > "$S/complexity-score.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$S/pr-authorship.sh"
chmod +x "$S"/*.sh

export FX="$TMP/fx" POSTED="$TMP/posted"
mkdir -p "$FX" "$TMP/bin"
cat > "$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
args="$*"
jqexpr=""; prev=""; body=""
for a in "$@"; do
  [[ "$prev" == "--jq" ]] && jqexpr="$a"
  [[ "$prev" == "--body" ]] && body="$a"
  prev="$a"
done
serve() { if [[ -n "$jqexpr" ]]; then jq -r "$jqexpr" "$1"; else cat "$1"; fi; }
case "$args" in
  "repo view"*) echo "acme/one" ;;
  "api user"*) echo "me" ;;
  "api repos/acme/one/pulls/99600") printf '{"number":99600,"state":"open","draft":false,"user":{"login":"me"}}\n' ;;
  "pr view"*"-q"*) echo "$FIXTURE_HEAD" ;;
  "pr view"*) printf '{"headRefOid":"%s","state":"OPEN"}\n' "$FIXTURE_HEAD" ;;
  "pr comment"*)
    if [[ -n "${FIXTURE_POST_FAIL:-}" && "$body" == "$FIXTURE_POST_FAIL" ]]; then
      # FIXTURE_RACE_HEAD: a newer push claims while this post is failing.
      [[ -n "${FIXTURE_RACE_HEAD:-}" ]] && bash "$FIXTURE_SS" --repo acme/one \
        --set ".prs[\"99600\"].review_request_head_sha=\"$FIXTURE_RACE_HEAD\"" >/dev/null 2>&1
      exit 1
    fi
    echo "$body" >> "$POSTED"
    if [[ -z "${FIXTURE_INVISIBLE:-}" ]]; then
      jq --arg b "$body" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '. + [{user: {login: "me"}, body: $b, created_at: $at, updated_at: $at}]' "$FX/comments.json" > "$FX/c.tmp" \
        && mv "$FX/c.tmp" "$FX/comments.json"
    fi ;;
  *"/issues/"*"/comments"*) serve "$FX/comments.json" ;;
  *"/pulls/"*"/reviews"*) echo '[]' ;;
  *"/check-runs"*) serve "$FX/checks.json" ;;
  *"/timeline"*) echo '[]' | jq -r "${jqexpr:-.}" ;;
  *"/commits/"*) serve "$FX/commit.json" ;;
  *) echo "unexpected gh call: $args" >&2; exit 1 ;;
esac
EOF
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH"

WORK="$TMP/work"
mkdir -p "$WORK"
git -C "$WORK" init -q
git -C "$WORK" remote add origin https://github.com/acme/one.git

ago() { jq -rn --argjson s "$1" 'now - $s | floor | todate'; }
tier_json() { printf '{"policy":"%s","gate":"%s","tier":"t","source":"base:main","error":null,"matches":[],"escalation":"on"}' "$1" "$2"; }
checks() { # <conclusion|null> <secs ago> [status]
  jq -cn --arg c "$1" --arg at "$(ago "$2")" --arg st "${3:-completed}" \
    '{check_runs: [{id: 1, name: "build", status: $st, conclusion: (if $c == "null" then null else $c end),
       check_suite: {id: 1}, app: {slug: "github-actions", id: 1}, started_at: $at, created_at: $at}]}' > "$FX/checks.json"
  jq -cn --arg d "$(ago "$2")" '{commit: {committer: {date: $d}}}' > "$FX/commit.json"
}
OK_CAP='{"platform":"bugbot","date":"2026-10-08","spent_usd":1,"add_usd":1.58,"cap_usd":10,"status":"ok"}'
reset() { # <tier json>
  export FIXTURE_TIER_OUT="$1" FIXTURE_TIER_RC=0 FIXTURE_HEAD="$HEAD" FIXTURE_ROUNDS=3
  export FIXTURE_REFUSED="" FIXTURE_CAP_OUT="$OK_CAP" FIXTURE_CAP_RC=0 FIXTURE_POST_FAIL="" FIXTURE_INVISIBLE=""
  export FIXTURE_CAP_FLIP="" FIXTURE_CAP_OVER=""
  rm -f "$HOME/.claude/session-state.json"
  : > "$POSTED"
  echo '[]' > "$FX/comments.json"
  checks success 7200
}
OUT=""; RC=0; ERR=""
run() { RC=0; OUT="$(cd "$WORK" && bash "$S/maybe-trigger-ai-review.sh" "$PR" --json "$@" 2>"$TMP/err")" || RC=$?; ERR="$(cat "$TMP/err")"; }
posted() { tr '\n' ';' < "$POSTED"; }
f() { jq -r "$1" <<<"$OUT" 2>/dev/null; }
ledger() { ( cd "$WORK" && bash "$S/session-state.sh" --repo acme/one --get-json ".prs[\"$PR\"].review_trigger_ledger.$1.count" 2>/dev/null ) || echo null; }


# Legacy path with the no-review window on the tier JSON: availability_gate runs, so the
# request goes to the free reviewer choose picks.
NRO_TIER='{"policy":"absent","gate":"legacy","tier":"t","source":"base:main","error":null,"matches":[],"escalation":"on","no_review_override_minutes":10}'
NOW_E=$(date -u +%s)
LIMIT_CA=$(jq -cn --argjson n "$((NOW_E + 1200))" --argjson t "$NOW_E" \
  '{next_available_epoch: $n, next_available: ($n | todateiso8601), notice_epoch: $t, notice_at: ($t | todateiso8601), window_seconds: ($n - $t), notice_excerpt: "x", source_repo: "acme/one", source_pr: 1, read_at: ($t | todateiso8601)}')
EIGHT=$(jq -cn --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '[range(8) | $t]')
# write_av <review_availability json> [cr hourly events json]: account-wide state before the tick.
write_av() {
  jq -cn --argjson av "$1" --argjson ev "${2:-[]}" '{schema_version: 1, review_availability: $av, cr_hourly: {events: $ev}}' > "$HOME/.claude/session-state.json"
}
# choice_of <pr>: the reviewer recorded for this PR's current HEAD.
choice_of() {
  ( cd "$WORK" && bash "$S/session-state.sh" --repo acme/one --get ".prs[\"$1\"].review_request_choices[\"$HEAD\"].reviewer" 2>/dev/null ) || echo null
}

echo "== fresh state: both free reviewers, CodeAnt answers first =="
reset "$NRO_TIER"
write_av '{}'
run
check_eq "exit 0" "0" "$RC"
check_eq "one request: the CodeAnt anchor line" "@codeant-ai review;" "$(posted)"
check_eq "the choice is recorded for this PR and HEAD" "codeant" "$(choice_of "$PR")"

echo "== CodeAnt limited: CodeRabbit is asked, with the exact anchor line =="
reset "$NRO_TIER"
write_av "{\"codeant\":$LIMIT_CA}"
run
check_eq "exit 0" "0" "$RC"
check_eq "posted body is exactly the CodeRabbit anchor" "@coderabbitai review;" "$(posted)"
check_eq "no full review is requested" "0" "$(grep -c 'full review' "$POSTED")"
check_eq "request_reviewer in --json" "coderabbit" "$(f .request_reviewer)"
check_eq "the choice is recorded" "coderabbit" "$(choice_of "$PR")"

echo "== CodeRabbit hourly budget spent: CodeAnt, though CodeRabbit would answer first =="
reset "$NRO_TIER"
write_av '{}' "$EIGHT"
REVIEW_EXPECTED_RESPONSE_CODERABBIT_MIN=1 run
check_eq "posted CodeAnt" "@codeant-ai review;" "$(posted)"

echo "== CodeRabbit budget spent between the choice and the post: falls back to CodeAnt =="
reset "$NRO_TIER"
write_av '{}'
cp "$S/cr-review-hourly.sh" "$TMP/cr-review-hourly.real"
cat > "$S/cr-review-hourly.sh" <<STUB
#!/usr/bin/env bash
# First --check (the choice) has budget; every later --check (the reserve) is spent.
n=\$(cat "$TMP/cr-check-count" 2>/dev/null || echo 0); n=\$((n + 1)); echo "\$n" > "$TMP/cr-check-count"
case "\$1" in --check) [ "\$n" -le 1 ] && exit 0 || exit 1 ;; *) exit 0 ;; esac
STUB
chmod +x "$S/cr-review-hourly.sh"; rm -f "$TMP/cr-check-count"
REVIEW_EXPECTED_RESPONSE_CODERABBIT_MIN=1 run
check_eq "budget lost after the choice: CodeAnt is asked instead" "@codeant-ai review;" "$(posted)"
check_eq "budget lost after the choice: the choice records CodeAnt" "codeant" "$(choice_of "$PR")"
cp "$TMP/cr-review-hourly.real" "$S/cr-review-hourly.sh"

echo "== CodeRabbit post fails: no budget spent, no request logged, claim released =="
reset "$NRO_TIER"
write_av "{\"codeant\":$LIMIT_CA}"
export FIXTURE_POST_FAIL="@coderabbitai review"
run
check_eq "nothing posted" "" "$(posted)"
check_eq "hourly budget not consumed" "0" "$(jq '(.cr_hourly.events // []) | length' "$HOME/.claude/session-state.json")"
check_eq "request log not advanced" "0" "$(jq '(.review_requests // []) | length' "$HOME/.claude/session-state.json")"
check_eq "no choice recorded" "null" "$(choice_of "$PR")"
check_eq "the HEAD claim is given back" "" "$( ( cd "$WORK" && bash "$S/session-state.sh" --repo acme/one --get ".prs[\"$PR\"].review_request_head_sha // empty" ) 2>/dev/null)"
# A newer push's claim survives this HEAD's release (compare-and-set, #2274 review).
reset "$NRO_TIER"
write_av "{\"codeant\":$LIMIT_CA}"
export FIXTURE_POST_FAIL="@coderabbitai review" FIXTURE_SS="$S/session-state.sh" FIXTURE_RACE_HEAD="$HEAD2"
run
export FIXTURE_RACE_HEAD=""
check_eq "a newer HEAD's claim is not cleared by this HEAD's failed post" "$HEAD2" "$( ( cd "$WORK" && bash "$S/session-state.sh" --repo acme/one --get ".prs[\"$PR\"].review_request_head_sha // empty" ) 2>/dev/null)"

echo "== override off (no window): the free reviewer is still chosen, never skipped =="
reset "$(tier_json absent legacy)"
write_av "{\"codeant\":$LIMIT_CA}"
run
check_eq "override off, CodeAnt limited: CodeRabbit asked" "@coderabbitai review;" "$(posted)"
reset "$(tier_json absent legacy)"
write_av "{\"codeant\":$LIMIT_CA,\"coderabbit\":$LIMIT_CA}"
run
check_eq "override off, both limited: still asks (no skip)" "@codeant-ai review;" "$(posted)"

echo "== override off: CodeRabbit budget spent after the choice, CodeAnt limited: still asks CodeAnt =="
reset "$(tier_json absent legacy)"
write_av "{\"codeant\":$LIMIT_CA}"
cat > "$S/cr-review-hourly.sh" <<STUB
#!/usr/bin/env bash
n=\$(cat "$TMP/cr-check-count" 2>/dev/null || echo 0); n=\$((n + 1)); echo "\$n" > "$TMP/cr-check-count"
case "\$1" in --check) [ "\$n" -le 1 ] && exit 0 || exit 1 ;; *) exit 0 ;; esac
STUB
chmod +x "$S/cr-review-hourly.sh"; rm -f "$TMP/cr-check-count"
run
check_eq "override off, budget lost, CodeAnt limited: asks CodeAnt (no silent skip)" "@codeant-ai review;" "$(posted)"
cp "$TMP/cr-review-hourly.real" "$S/cr-review-hourly.sh"

echo "== tiered repo: the tier's CodeAnt step always asks CodeAnt, even when CodeAnt is limited =="
reset '{"policy":"present","gate":"full","tier":"t","source":"base:main","error":null,"matches":[],"escalation":"on","no_review_override_minutes":10}'
write_av "{\"codeant\":$LIMIT_CA}"
run
check_eq "tiered: no CodeRabbit request" "0" "$(grep -c '@coderabbitai' "$POSTED")"
check_eq "tiered: the CodeAnt step posts CodeAnt" "1" "$(grep -c '^@codeant-ai review$' "$POSTED")"

echo "== both limited: nothing posted, skipped as increment 1 =="
reset "$NRO_TIER"
write_av "{\"codeant\":$LIMIT_CA,\"coderabbit\":$LIMIT_CA}"
run
check_eq "no comment" "" "$(posted)"
check_eq "skip reason names the no-reviewer window" "true" "$(f '.reason | startswith("review_request_no_reviewer_available_until")')"

echo "== several PRs going green together alternate reviewers =="
reset "$NRO_TIER"
write_av '{}'
run
PR=99601 run
check_eq "first PR asks CodeAnt, second asks CodeRabbit" "@codeant-ai review;@coderabbitai review;" "$(posted)"
check_eq "second PR's choice is recorded" "coderabbit" "$(choice_of 99601)"
echo "== summary: $PASS passed, $FAIL failed =="
[[ "$FAIL" -eq 0 ]] || exit 1
