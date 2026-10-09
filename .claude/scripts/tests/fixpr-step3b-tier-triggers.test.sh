#!/usr/bin/env bash
# /fixpr Step 3b under a review tier, and its unchanged legacy order (issue #1749).
# catalog: tests — Runs `fixpr-reviewer-triggers.sh` (/fixpr Step 3b) against fixture policies — ci-only posts no reviewer comment after a push, ci+codeant-one-round posts one CodeAnt invitation, full waits for green CI and posts CodeAnt and BugBot only, and a policy-free repo keeps the legacy four-trigger order
#
# WHAT IS UNDER TEST
#   The script /fixpr Step 3b runs after a push. With a `## Review policy` it
#   posts only what review-triggers-allowed.sh allows on the pushed SHA; with
#   none it posts exactly what the inline Step 3b did before #1749.
#
# HOW IT IS OBSERVED
#   REAL: fixpr-reviewer-triggers.sh, review-triggers-allowed.sh,
#   bugbot-tier-excluded.sh, ci-status.sh, check-runs-dedup.sh,
#   session-state.sh, pr-body-review-note.sh. Stubbed: review-tier.sh,
#   reviewer-activity.sh, bugbot-refused-head.sh, review-daily-cap.sh,
#   cr-review-hourly.sh, and `gh`, which records every posted comment and adds
#   it to the PR's comments the way GitHub would.

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

PR=99800
SHA="1212121212121212121212121212121212121212"

S="$TMP/scripts"
mkdir -p "$S/lib" "$TMP/reference"
for f in fixpr-reviewer-triggers.sh review-triggers-allowed.sh bugbot-tier-excluded.sh ci-status.sh \
         check-runs-dedup.sh session-state.sh state-lock.sh pr-body-review-note.sh; do
  cp "$REPO_ROOT/.claude/scripts/$f" "$S/"
done
cp "$REPO_ROOT/.claude/scripts/lib/repo-normalizer.sh" "$REPO_ROOT/.claude/scripts/lib/codeant-round.jq" "$S/lib/"
cp "$REPO_ROOT/.claude/reference/session-state-schema.json" "$TMP/reference/"
cat > "$S/review-tier.sh" <<'EOF'
#!/usr/bin/env bash
[[ -n "${FIXTURE_TIER_OUT:-}" ]] && printf '%s\n' "$FIXTURE_TIER_OUT"
exit 0
EOF
cat > "$S/reviewer-activity.sh" <<'EOF'
#!/usr/bin/env bash
printf 'activity %s GH_REPO=%s\n' "$*" "${GH_REPO:-}" >> "$CALLS"
if [[ -n "${FIXTURE_ACTIVE:-}" ]]; then echo "$FIXTURE_ACTIVE"
else echo '{"coderabbit":false,"graphite":false,"codeant":false}'; fi
EOF
printf '#!/usr/bin/env bash\nexit 1\n' > "$S/bugbot-refused-head.sh"
cat > "$S/review-daily-cap.sh" <<'EOF'
#!/usr/bin/env bash
if [[ " $* " == *" --rate "* ]]; then echo 1.58; exit 0; fi
printf '%s\n' "$FIXTURE_CAP_OUT"
exit "${FIXTURE_CAP_RC:-0}"
EOF
cat > "$S/cr-review-hourly.sh" <<'EOF'
#!/usr/bin/env bash
printf 'cr-hourly %s\n' "$*" >> "$CALLS"
exit 0
EOF
chmod +x "$S"/*.sh

export FX="$TMP/fx" POSTED_LOG="$TMP/posted" CALLS="$TMP/calls" GH_BODY="$TMP/body.md"
mkdir -p "$FX" "$TMP/bin"
cat > "$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
args="$*"
jqexpr=""; prev=""; body=""; bodyfile=""
for a in "$@"; do
  [[ "$prev" == "--jq" ]] && jqexpr="$a"
  [[ "$prev" == "--body" ]] && body="$a"
  [[ "$prev" == "--body-file" ]] && bodyfile="$a"
  prev="$a"
done
serve() { if [[ -n "$jqexpr" ]]; then jq -r "$jqexpr" "$1"; else cat "$1"; fi; }
case "$args" in
  "repo view"*) echo "acme/one" ;;
  "pr view"*"headRefOid"*) printf '{"headRefOid":"%s","state":"OPEN"}\n' "$FIXTURE_HEAD" ;;
  "pr view"*"body"*) cat "$GH_BODY" ;;
  "pr edit"*) cp "$bodyfile" "$GH_BODY" ;;
  "pr comment"*)
    [[ -n "${FIXTURE_POST_FAIL:-}" && "$body" == "$FIXTURE_POST_FAIL" ]] && exit 1
    echo "$body" >> "$POSTED_LOG"
    jq --arg b "$body" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      '. + [{user: {login: "me"}, body: $b, created_at: $at, updated_at: $at}]' "$FX/comments.json" > "$FX/c.tmp" \
      && mv "$FX/c.tmp" "$FX/comments.json" ;;
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
  export FIXTURE_TIER_OUT="$1" FIXTURE_HEAD="$SHA" FIXTURE_ACTIVE="" FIXTURE_POST_FAIL=""
  export FIXTURE_CAP_OUT="$OK_CAP" FIXTURE_CAP_RC=0
  rm -f "$HOME/.claude/session-state.json"
  : > "$POSTED_LOG"; : > "$CALLS"
  echo '[]' > "$FX/comments.json"
  printf '## Summary\n\nA change.\n\n## Test plan\n\n- [ ] works\n' > "$GH_BODY"
  checks success 7200
}
OUT=""
step3b() { OUT="$(cd "$WORK" && bash "$S/fixpr-reviewer-triggers.sh" "$PR" --repo acme/one \
  --pushed-sha "$SHA" --pushed-at "$(ago 150)" 2>"$TMP/err")"; }
posted() { tr '\n' ';' < "$POSTED_LOG"; }
says() { [[ "$OUT" == *"$1"* ]] && echo yes || echo no; }
ledger() { ( cd "$WORK" && bash "$S/session-state.sh" --repo acme/one --get-json ".prs[\"$PR\"].review_trigger_ledger.$1.count" 2>/dev/null ) || echo null; }

############################################################################
echo "== no ## Review policy: the legacy order and conditions, unchanged =="
reset "$(tier_json absent legacy)"
step3b
check_eq "all four, in the legacy order" "@coderabbitai full review;@graphite-app re-review;@codeant-ai review;@cursor review;" "$(posted)"
check_eq "the CodeRabbit slot was recorded" "cr-hourly --record-explicit $PR" "$(grep '^cr-hourly' "$CALLS")"
check_eq "reviewer activity asked about the pushed SHA in this repo" "yes" "$(grep -q "^activity $PR $SHA .* GH_REPO=acme/one$" "$CALLS" && echo yes || echo no)"
check_eq "mode line" "yes" "$(says 'TRIGGER_MODE=legacy')"
reset "$(tier_json absent legacy)"
export FIXTURE_ACTIVE='{"coderabbit":true,"graphite":false,"codeant":true}'
step3b
check_eq "active reviewers are not re-triggered" "@graphite-app re-review;@cursor review;" "$(posted)"
reset "$(tier_json absent legacy)"
jq -cn --arg at "$(ago 600)" '[range(2) | {user: {login: "me"}, body: "@coderabbitai full review", created_at: $at}]' > "$FX/comments.json"
step3b
check_eq "two CodeRabbit triggers in the last hour: CodeRabbit skipped, the rest post" "@graphite-app re-review;@codeant-ai review;@cursor review;" "$(posted)"
check_eq "  and says why" "yes" "$(says 'coderabbit trigger budget exhausted')"

echo "== ci-only: a push draws NO reviewer comment =="
reset "$(tier_json present ci-only)"
step3b
check_eq "nothing posted" "" "$(posted)"
check_eq "mode line" "yes" "$(says 'TRIGGER_MODE=tiered')"
check_eq "names the skip" "yes" "$(says 'skipping @cursor review — review tier ci-only: tier_excluded')"
check_eq "no CodeRabbit slot recorded" "" "$(grep '^cr-hourly' "$CALLS")"

echo "== ci+codeant-one-round: one CodeAnt invitation, nothing else =="
reset "$(tier_json present ci+codeant-one-round)"
step3b
check_eq "only @codeant-ai review" "@codeant-ai review;" "$(posted)"
check_eq "claimed" "1" "$(ledger codeant)"
step3b
check_eq "the next push posts nothing" "@codeant-ai review;" "$(posted)"
check_eq "  CodeAnt's lifetime cap" "yes" "$(says 'skipping @codeant-ai review — review tier ci+codeant-one-round: lifetime_cap')"

echo "== full: right after a push CI is pending, so nothing posts yet =="
reset "$(tier_json present full)"
checks null 60 in_progress
step3b
check_eq "nothing posted" "" "$(posted)"
check_eq "deferral named" "yes" "$(says 'deferring @cursor review — review tier full: ci_pending')"
checks success 7200
step3b
check_eq "green and settled: CodeAnt and BugBot only" "@codeant-ai review;@cursor review;" "$(posted)"
check_eq "  never Graphite" "yes" "$(says 'skipping @graphite-app re-review — review tier full: tier_excluded')"
check_eq "  CodeRabbit is not the fallback" "yes" "$(says 'skipping @coderabbitai full review — review tier full: not_fallback')"

echo "== full: an active reviewer is never re-triggered =="
reset "$(tier_json present full)"
export FIXTURE_ACTIVE='{"coderabbit":false,"graphite":false,"codeant":true}'
step3b
check_eq "CodeAnt active on the pushed SHA: only BugBot" "@cursor review;" "$(posted)"
check_eq "  no CodeAnt claim" "null" "$(ledger codeant)"

echo "== full: the daily cap still writes its PR-body note =="
reset "$(tier_json present full)"
export FIXTURE_CAP_OUT='{"platform":"bugbot","date":"2026-10-08","spent_usd":9.5,"add_usd":1.58,"cap_usd":10,"status":"over"}' FIXTURE_CAP_RC=1
step3b
check_eq "BugBot skipped, CodeAnt posted" "@codeant-ai review;" "$(posted)"
check_eq "the note is in the body" "1" "$(grep -cF 'BugBot skipped: daily cap ($9.50 of $10.00 today)' "$GH_BODY" | tr -d ' ')"
check_eq "  under ## Review notes" "1" "$(grep -c '^## Review notes' "$GH_BODY" | tr -d ' ')"

echo "== full: a failed post releases its claim =="
reset "$(tier_json present full)"
export FIXTURE_POST_FAIL="@cursor review"
step3b
check_eq "BugBot not posted" "@codeant-ai review;" "$(posted)"
check_eq "  its claim released" "0" "$(ledger cursor)"
check_eq "  and said so" "yes" "$(grep -q 'FAILED to post @cursor review — releasing its claim' "$TMP/err" && echo yes || echo no)"

echo "== usage =="
RC=0; bash "$S/fixpr-reviewer-triggers.sh" "$PR" --repo acme/one --pushed-at x >/dev/null 2>&1 || RC=$?
check_eq "no --pushed-sha: exit 2" "2" "$RC"
check_eq "--help prints the header" "yes" "$(grep -q '^PURPOSE' <<<"$(bash "$S/fixpr-reviewer-triggers.sh" --help)" && echo yes || echo no)"

echo
echo "== summary: $PASS passed, $FAIL failed =="
[[ "$FAIL" -eq 0 ]] || exit 1
echo "OK: fixpr Step 3b tier-aware trigger tests passed"
