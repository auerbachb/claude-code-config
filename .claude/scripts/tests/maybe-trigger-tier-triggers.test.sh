#!/usr/bin/env bash
# Offline tests for the tier-aware trigger path of maybe-trigger-ai-review.sh (issue #1749).
# catalog: tests — Tests `maybe-trigger-ai-review.sh` under a review tier — ci-only posts nothing, ci+codeant-one-round posts one CodeAnt invitation for the life of the PR, full defers BugBot until CI is green and HEAD settled, a policy-free repo posts the free reviewers, and an owner grant (#1898) posts BugBot exactly once on its own PR and HEAD
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
         check-runs-dedup.sh session-state.sh state-lock.sh; do
  cp "$REPO_ROOT/.claude/scripts/$f" "$S/"
done
cp "$REPO_ROOT/.claude/scripts/lib/repo-normalizer.sh" "$REPO_ROOT/.claude/scripts/lib/ts-normalizer.sh" \
   "$REPO_ROOT/.claude/scripts/lib/codeant-round.jq" "$S/lib/"
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
printf '#!/usr/bin/env bash\necho 500\n' > "$S/complexity-score.sh"
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
  "pr view"*"-q"*) echo "$FIXTURE_HEAD" ;;
  "pr view"*) printf '{"headRefOid":"%s","state":"OPEN"}\n' "$FIXTURE_HEAD" ;;
  "pr comment"*)
    [[ -n "${FIXTURE_POST_FAIL:-}" && "$body" == "$FIXTURE_POST_FAIL" ]] && exit 1
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

############################################################################
echo "== no ## Review policy: the legacy path, unchanged, with the helper present =="
reset "$(tier_json absent legacy)"
run
check_eq "exit 0" "0" "$RC"
check_eq "the free reviewers post, in order; BugBot needs owner approval (#1897)" "@codeant-ai review;@graphite-app re-review;" "$(posted)"
check_eq "legacy status" "triggered" "$(f .status)"
check_eq "no tier fields on the legacy path" "null" "$(f .trigger_mode)"
check_eq "no ledger written" "null" "$(ledger codeant)"

echo "== ci-only: nothing is posted, and the tick completes =="
reset "$(tier_json present ci-only)"
run
check_eq "exit 0" "0" "$RC"
check_eq "no comment" "" "$(posted)"
check_eq "status skipped/tier_excluded" "skipped:tier_excluded" "$(f '"\(.status):\(.reason)"')"
check_eq "trigger_mode tiered" "tiered" "$(f .trigger_mode)"
check_eq "every skip is the tier" "tier_excluded,tier_excluded,tier_excluded" "$(f '[.trigger_skips.codeant.reason, .trigger_skips.cursor.reason, .trigger_skips.graphite.reason] | join(",")')"
check_eq "bugbot_skipped keeps its shape" "review_tier:ci-only" "$(f '"\(.bugbot_skipped.reason):\(.bugbot_skipped.gate)"')"
run
check_eq "the next tick is a duplicate" "duplicate_poll_tick" "$(f .reason)"

echo "== ci+codeant-one-round: one CodeAnt invitation for the life of the PR =="
reset "$(tier_json present ci+codeant-one-round)"
run
check_eq "only @codeant-ai review" "@codeant-ai review;" "$(posted)"
check_eq "status triggered" "triggered" "$(f .status)"
check_eq "claimed in the ledger" "1" "$(ledger codeant)"
export FIXTURE_ROUNDS=5 FIXTURE_HEAD="$HEAD2"
run
check_eq "a later round on a new HEAD posts nothing" "@codeant-ai review;" "$(posted)"
check_eq "  codeant hit its lifetime cap" "lifetime_cap" "$(f .trigger_skips.codeant.reason)"
check_eq "  no BugBot, no Graphite" "tier_excluded:tier_excluded" "$(f '"\(.trigger_skips.cursor.reason):\(.trigger_skips.graphite.reason)"')"
reset "$(tier_json present ci+codeant-one-round)"
export FIXTURE_INVISIBLE=1
run
export FIXTURE_ROUNDS=5 FIXTURE_HEAD="$HEAD2"
run
check_eq "the ledger alone bounds the cap before GitHub lists the comment" "@codeant-ai review;" "$(posted)"

echo "== full: BugBot waits for green CI and a settled HEAD, at most twice =="
reset "$(tier_json present full)"
checks null 30 in_progress
run
check_eq "CI pending: nothing posted" "" "$(posted)"
check_eq "status skipped/tier_deferred" "skipped:tier_deferred" "$(f '"\(.status):\(.reason)"')"
check_eq "codeant and cursor deferred" '["codeant","cursor"]' "$(f '.deferred | tostring')"
checks success 60
run
check_eq "the same tick again is NOT a duplicate: CodeAnt posts once CI is green" "@codeant-ai review;" "$(posted)"
check_eq "  cursor waits for the settle" "head_not_settled" "$(f .trigger_skips.cursor.reason)"
checks success 7200
run
check_eq "settled: still no @cursor review (owner approval required), CodeAnt is not re-posted" "@codeant-ai review;" "$(posted)"
check_eq "  cursor excluded approval_required — the last step, after the settle" "approval_required" "$(f .trigger_skips.cursor.reason)"
run
check_eq "the round is complete: duplicate tick" "duplicate_poll_tick" "$(f .reason)"
export FIXTURE_ROUNDS=5 FIXTURE_HEAD="$HEAD2"
run
check_eq "next round: no BugBot invitation either" "@codeant-ai review;" "$(posted)"
export FIXTURE_ROUNDS=7 FIXTURE_HEAD="$HEAD"
run
check_eq "third round: still no BugBot" "@codeant-ai review;" "$(posted)"
check_eq "  approval_required (never invited, so the lifetime cap is never reached)" "approval_required" "$(f .trigger_skips.cursor.reason)"
check_eq "  Graphite never" "tier_excluded" "$(f .trigger_skips.graphite.reason)"

echo "== full: the daily cap and a refused HEAD still skip BugBot =="
reset "$(tier_json present full)"
export FIXTURE_CAP_OUT='{"platform":"bugbot","date":"2026-10-08","spent_usd":9.5,"add_usd":1.58,"cap_usd":10,"status":"over"}' FIXTURE_CAP_RC=1
run
check_eq "over: only CodeAnt" "@codeant-ai review;" "$(posted)"
check_eq "  bugbot_skipped daily_cap with the tally" "daily_cap:9.5" "$(f '"\(.bugbot_skipped.reason):\(.bugbot_skipped.tally.spent_usd)"')"
check_eq "  bugbot_daily_cap reported" "over" "$(f .bugbot_daily_cap.status)"
check_eq "  deferred, so the next tick re-asks" '["cursor"]' "$(f '.deferred | tostring')"
run
check_eq "  and it does: not a duplicate tick, still only CodeAnt" "@codeant-ai review;:daily_cap" "$(posted):$(f .trigger_skips.cursor.reason)"
reset "$(tier_json present full)"
export FIXTURE_CAP_FLIP="$TMP/cap-flip" FIXTURE_CAP_OVER='{"platform":"bugbot","date":"2026-10-08","spent_usd":9.9,"add_usd":1.58,"cap_usd":10,"status":"over"}'
rm -f "$FIXTURE_CAP_FLIP"
run
check_eq "an ok cap at evaluation: approval decides, so no claim is ever made" "@codeant-ai review;:approval_required" "$(posted):$(f .trigger_skips.cursor.reason)"
check_eq "  bugbot_skipped is the approval skip" "approval_required:null" "$(f '"\(.bugbot_skipped.reason):\(.bugbot_skipped.tally.spent_usd)"')"
check_eq "  bugbot_daily_cap is the evaluation tally" "ok" "$(f .bugbot_daily_cap.status)"
reset "$(tier_json present full)"
export FIXTURE_REFUSED=1
run
check_eq "refused HEAD: only CodeAnt" "@codeant-ai review;" "$(posted)"
check_eq "  bugbot_skipped refused_head" "refused_head" "$(f .bugbot_skipped.reason)"
run
check_eq "  handled for this HEAD: the tick completes" "duplicate_poll_tick" "$(f .reason)"

echo "== a failed post releases its claim =="
reset "$(tier_json present full)"
# Retargeted to CodeAnt (issue #1897): BugBot is never claimed any more.
export FIXTURE_POST_FAIL="@codeant-ai review"
run
check_eq "exit 5" "5" "$RC"
check_eq "nothing posted" "" "$(posted)"
check_eq "the codeant claim was released" "0" "$(ledger codeant)"
check_eq "no cursor claim was ever made" "null" "$(ledger cursor)"
export FIXTURE_POST_FAIL=""
run
check_eq "the retry posts CodeAnt, never BugBot" "@codeant-ai review;" "$(posted)"

echo "== --dry-run evaluates, never claims =="
reset "$(tier_json present full)"
run --dry-run
check_eq "dry_run status" "dry_run" "$(f .status)"
check_eq "nothing posted" "" "$(posted)"
check_eq "nothing claimed" "null" "$(ledger codeant)"
check_eq "trigger mode reported" "tiered" "$(f .trigger_mode)"
OUT_TXT="$(cd "$WORK" && bash "$S/maybe-trigger-ai-review.sh" "$PR" --dry-run 2>/dev/null)"
check_eq "text dry run names what would post" "yes" "$( [[ "$OUT_TXT" == *"would post codeant;"*"cursor=approval_required"* ]] && echo yes || echo no )"

echo "== an owner grant (#1898): one @cursor review on that PR and HEAD, never more =="
# The helper and an authorship stub join the stub dir only now, so every case
# above ran with no grant helper at all (the fail-closed path).
cp "$REPO_ROOT/.claude/scripts/paid-review-grant.sh" "$S/"
printf '#!/usr/bin/env bash\nexit 0\n' > "$S/pr-authorship.sh"
chmod +x "$S/paid-review-grant.sh" "$S/pr-authorship.sh"
export CLAUDE_CODE_SESSION_ID="grant-test-session"
unset CLAUDE_CODE_CHILD_SESSION CLAUDE_CODE_SESSION_ATTENDED
grant_for() { # <head>
  ( cd "$WORK" && bash "$S/paid-review-grant.sh" --grant "$PR" --vendor cursor --head "$1" \
      --price-usd 1.58 --approved-via chat --question "Approve one BugBot review?" --repo acme/one >/dev/null 2>&1 )
}
grant_status() {
  ( cd "$WORK" && bash "$S/session-state.sh" --repo acme/one --get ".prs[\"$PR\"].paid_review_grants.cursor.status" 2>/dev/null ) || echo unreadable
}
reset "$(tier_json absent legacy)"
grant_for "$HEAD"
run
check_eq "legacy: exit 0" "0" "$RC"
check_eq "legacy: BugBot posted once, between the free reviewers" "@codeant-ai review;@cursor review;@graphite-app re-review;" "$(posted)"
check_eq "legacy: no approval skip reported" "null" "$(f .bugbot_skipped)"
check_eq "legacy: the grant is used" "consumed" "$(grant_status)"
export FIXTURE_ROUNDS=5
run
check_eq "legacy: the next round on the same HEAD posts no second @cursor review" "@codeant-ai review;@cursor review;@graphite-app re-review;@codeant-ai review;@graphite-app re-review;" "$(posted)"
check_eq "legacy: the approval skip is back" "approval_required" "$(f .bugbot_skipped.reason)"
reset "$(tier_json absent legacy)"
grant_for "$HEAD"
export FIXTURE_HEAD="$HEAD2"
run
check_eq "legacy: a grant for the old HEAD never posts on a new push" "@codeant-ai review;@graphite-app re-review;" "$(posted)"
check_eq "legacy: the stale grant stays unused" "unused" "$(grant_status)"
reset "$(tier_json absent legacy)"
grant_for "$HEAD"
printf '{ not json' > "$HOME/.claude/session-state.json"
run
check_eq "legacy: unreadable state posts no @cursor review" "no" "$( [[ "$(posted)" == *"@cursor review"* ]] && echo yes || echo no )"
check_eq "legacy: unreadable state leaves a visible note" "yes" "$( [[ "$ERR" == *"no paid review"* || "$ERR" == *"session state"* ]] && echo yes || echo no )"
reset "$(tier_json present full)"
grant_for "$HEAD"
run
check_eq "full, settled: CodeAnt and BugBot (under the grant)" "@codeant-ai review;@cursor review;" "$(posted)"
check_eq "full: the cursor skip is gone" "null" "$(f .trigger_skips.cursor)"
check_eq "full: status triggered" "triggered" "$(f .status)"
check_eq "full: the grant is used" "consumed" "$(grant_status)"
reset "$(tier_json present full)"
grant_for "$HEAD"
export FIXTURE_POST_FAIL="@cursor review"
run
check_eq "full: a failed BugBot post releases the grant" "unused" "$(grant_status)"
check_eq "full: a failed BugBot post exits 5, like any failed post" "5" "$RC"
check_eq "full: a failed BugBot post reports trigger_failed, not approval_required" "yes" "$( [[ "$ERR" == *"trigger_failed"* ]] && echo yes || echo no )"
reset "$(tier_json absent legacy)"
grant_for "$HEAD"
export FIXTURE_POST_FAIL="@cursor review"
run
check_eq "legacy: a failed BugBot post exits 5" "5" "$RC"
check_eq "legacy: a failed BugBot post reports trigger_failed" "yes" "$( [[ "$ERR" == *"trigger_failed"* ]] && echo yes || echo no )"
check_eq "legacy: a failed BugBot post releases the grant" "unused" "$(grant_status)"
export FIXTURE_POST_FAIL=""
unset CLAUDE_CODE_SESSION_ID
rm -f "$S/paid-review-grant.sh" "$S/pr-authorship.sh"

echo "== an unresolvable tier on a policy repo posts nothing =="
reset ""
export FIXTURE_TIER_RC=4
mkdir -p "$WORK/.claude"
printf '## Review policy\n\n| Tier | Gate | Paths |\n|---|---|---|\n| core | full | src/** |\n' > "$WORK/.claude/pm-config.md"
mkdir -p "$TMP/real"
cp "$REPO_ROOT/.claude/scripts/review-tier.sh" "$REPO_ROOT/.claude/scripts/pm-config-get.sh" "$TMP/real/"
# The probe runs the resolver offline; give the stub the real one's answer for it.
cat > "$S/review-tier.sh" <<EOF
#!/usr/bin/env bash
if [[ " \$* " == *" --files-from "* ]]; then exec bash "$TMP/real/review-tier.sh" "\$@"; fi
exit 4
EOF
chmod +x "$S/review-tier.sh"
run
check_eq "nothing posted" "" "$(posted)"
check_eq "fail_closed mode" "fail_closed" "$(f .trigger_mode)"
check_eq "deferred for every step" '["codeant","cursor","graphite"]' "$(f '.deferred | tostring')"
rm -f "$WORK/.claude/pm-config.md"
run
check_eq "the same failure on a policy-free checkout: legacy, the free reviewers post" "@codeant-ai review;@graphite-app re-review;" "$(posted)"

echo
echo "== summary: $PASS passed, $FAIL failed =="
[[ "$FAIL" -eq 0 ]] || exit 1
echo "OK: maybe-trigger-ai-review.sh tier-aware trigger tests passed"
