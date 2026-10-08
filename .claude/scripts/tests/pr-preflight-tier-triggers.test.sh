#!/usr/bin/env bash
# Offline tests for the tier-aware reviewer loop of pr-preflight.sh (issue #1749).
# catalog: tests — Tests `pr-preflight.sh` under a review tier — ci-only triggers nothing and is clean, ci+codeant-one-round invites CodeAnt once, full defers BugBot until CI is green and HEAD settled and stops at two, and a policy-free repo still triggers all four
#
# WHAT IS UNDER TEST
#   pr-preflight.sh asks the shared review-triggers-allowed.sh once per run.
#   After its HEAD-scoped already-present check, an allowed reviewer is
#   claimed then posted, an excluded one is `skipped-tier-excluded` (clean),
#   a deferred one `skipped-tier-deferred` (not clean). Mode `legacy` runs the
#   old loop — proven here with the helper present.
#
# HOW IT IS OBSERVED
#   The REAL pr-preflight.sh runs in place against the REAL helper (in a stub
#   dir beside the real ci-status.sh, check-runs-dedup.sh, session-state.sh).
#   Stubbed: review-tier.sh, bugbot-refused-head.sh, review-daily-cap.sh,
#   cr-review-hourly.sh, and `gh`, which records each posted comment and adds
#   it to the PR's comment list the way GitHub would.

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SCRIPT="$REPO_ROOT/.claude/scripts/pr-preflight.sh"
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

PR=99700
HEAD="eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
HEAD2="ffffffffffffffffffffffffffffffffffffffff"

S="$TMP/scripts"
mkdir -p "$S/lib" "$TMP/reference"
for f in review-triggers-allowed.sh ci-status.sh check-runs-dedup.sh session-state.sh state-lock.sh; do
  cp "$REPO_ROOT/.claude/scripts/$f" "$S/"
done
cp "$REPO_ROOT/.claude/scripts/lib/repo-normalizer.sh" "$REPO_ROOT/.claude/scripts/lib/codeant-round.jq" "$S/lib/"
cp "$REPO_ROOT/.claude/reference/session-state-schema.json" "$TMP/reference/"
cat > "$S/review-tier.sh" <<'EOF'
#!/usr/bin/env bash
[[ -n "${FIXTURE_TIER_OUT:-}" ]] && printf '%s\n' "$FIXTURE_TIER_OUT"
exit 0
EOF
printf '#!/usr/bin/env bash\nexit 1\n' > "$S/bugbot-refused-head.sh"
cat > "$S/review-daily-cap.sh" <<'EOF'
#!/usr/bin/env bash
if [[ " $* " == *" --rate "* ]]; then echo 1.58; exit 0; fi
echo '{"platform":"bugbot","date":"2026-10-08","spent_usd":1,"add_usd":1.58,"cap_usd":10,"status":"ok"}'
EOF
cat > "$TMP/cr-hourly.sh" <<'EOF'
#!/usr/bin/env bash
[[ -n "${FIXTURE_CR_CAPPED:-}" && ( "$1" == "--check" || "$1" == "--peek-explicit" ) ]] && exit 1
exit 0
EOF
chmod +x "$S"/*.sh "$TMP/cr-hourly.sh"
export PREFLIGHT_TRIGGERS_ALLOWED_SH="$S/review-triggers-allowed.sh"
export PREFLIGHT_CR_HOURLY_SH="$TMP/cr-hourly.sh"
export PREFLIGHT_SESSION_STATE_SH="$TMP/no-such-session-state.sh"
export PREFLIGHT_REVIEW_SUBSTANCE_SH="$TMP/no-such-review-substance.sh"
export PREFLIGHT_BUGBOT_TIER_SH="$TMP/no-such-bugbot-tier-excluded.sh"

export FX="$TMP/fx" POSTED_LOG="$TMP/posted"
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
  "pr view"*"isDraft"*) printf '{"isDraft":false,"author":{"login":"me"},"state":"OPEN","headRefOid":"%s"}\n' "$FIXTURE_HEAD" ;;
  "pr view"*) printf '{"headRefOid":"%s","state":"OPEN"}\n' "$FIXTURE_HEAD" ;;
  "pr comment"*)
    [[ -n "${FIXTURE_POST_FAIL:-}" && "$body" == "$FIXTURE_POST_FAIL" ]] && exit 1
    echo "$body" >> "$POSTED_LOG"
    # Stamped an hour back, so a later scenario can place a newer HEAD after it.
    jq --arg b "$body" --arg at "$(jq -rn 'now - 3600 | floor | todate')" \
      '. + [{user: {login: "me"}, body: $b, created_at: $at, updated_at: $at}]' "$FX/comments.json" > "$FX/c.tmp" \
      && mv "$FX/c.tmp" "$FX/comments.json" ;;
  *"/pulls/"*"/comments"*) echo '[]' ;;
  *"/pulls/"*"/reviews"*) echo '[]' ;;
  *"/issues/"*"/comments"*) serve "$FX/comments.json" ;;
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
reset() { # <tier json>
  export FIXTURE_TIER_OUT="$1" FIXTURE_HEAD="$HEAD" FIXTURE_POST_FAIL="" FIXTURE_CR_CAPPED=""
  rm -f "$HOME/.claude/session-state.json"
  : > "$POSTED_LOG"
  echo '[]' > "$FX/comments.json"
  checks success 7200
}
OUT=""; RC=0
run() { RC=0; OUT="$(cd "$WORK" && bash "$SCRIPT" "$PR" --json "$@" 2>"$TMP/err")" || RC=$?; }
posted() { tr '\n' ';' < "$POSTED_LOG"; }
st() { jq -r ".reviewers.$1.status" <<<"$OUT" 2>/dev/null; }
statuses() { jq -r '[.reviewers.codeant.status, .reviewers.coderabbit.status, .reviewers.cursor.status, .reviewers.graphite.status] | join(",")' <<<"$OUT" 2>/dev/null; }
ledger() { ( cd "$WORK" && bash "$S/session-state.sh" --repo acme/one --get-json ".prs[\"$PR\"].review_trigger_ledger.$1.count" 2>/dev/null ) || echo null; }

############################################################################
echo "== no ## Review policy: the legacy loop, unchanged, with the helper present =="
reset "$(tier_json absent legacy)"
run
check_eq "exit 0" "0" "$RC"
check_eq "all four triggered" "triggered,triggered,triggered,triggered" "$(statuses)"
check_eq "posted in the legacy order" "@codeant-ai review;@coderabbitai full review;@cursor review;@graphite-app re-review;" "$(posted)"

echo "== ci-only: nothing posted, and clean =="
reset "$(tier_json present ci-only)"
run
check_eq "every reviewer skipped-tier-excluded" "skipped-tier-excluded,skipped-tier-excluded,skipped-tier-excluded,skipped-tier-excluded" "$(statuses)"
check_eq "nothing posted" "" "$(posted)"
check_eq "clean" "true" "$(jq -r .clean <<<"$OUT")"
check_eq "no actions" "0" "$(jq -r .actions <<<"$OUT")"

echo "== ci+codeant-one-round: CodeAnt once for the life of the PR =="
reset "$(tier_json present ci+codeant-one-round)"
run
check_eq "codeant triggered; the rest excluded" "triggered,skipped-tier-excluded,skipped-tier-excluded,skipped-tier-excluded" "$(statuses)"
check_eq "only @codeant-ai review posted" "@codeant-ai review;" "$(posted)"
check_eq "claimed" "1" "$(ledger codeant)"
run
check_eq "same HEAD: the trigger reads as already-present" "already-present" "$(st codeant)"
export FIXTURE_HEAD="$HEAD2"
checks success 60
run
check_eq "new HEAD: CodeAnt is not re-invited" "skipped-tier-excluded" "$(st codeant)"
check_eq "  still one post" "@codeant-ai review;" "$(posted)"
check_eq "  and clean" "true" "$(jq -r .clean <<<"$OUT")"

echo "== full: BugBot waits for green CI and a settled HEAD, at most twice =="
reset "$(tier_json present full)"
checks null 30 in_progress
run
check_eq "CI pending: codeant and cursor deferred, coderabbit/graphite excluded" "skipped-tier-deferred,skipped-tier-excluded,skipped-tier-deferred,skipped-tier-excluded" "$(statuses)"
check_eq "nothing posted" "" "$(posted)"
check_eq "deferred is NOT clean" "false" "$(jq -r .clean <<<"$OUT")"
checks success 7200
run
check_eq "green and settled: codeant and cursor triggered" "triggered,skipped-tier-excluded,triggered,skipped-tier-excluded" "$(statuses)"
check_eq "posted" "@codeant-ai review;@cursor review;" "$(posted)"
export FIXTURE_HEAD="$HEAD2"
checks success 1800
run
check_eq "new settled HEAD: the second BugBot invitation" "@codeant-ai review;@cursor review;@cursor review;" "$(posted)"
check_eq "  codeant stays at one" "skipped-tier-excluded" "$(st codeant)"
export FIXTURE_HEAD="$HEAD"
checks success 900
run
check_eq "third settled HEAD: BugBot capped at two" "skipped-tier-excluded" "$(st cursor)"
check_eq "  nothing new posted" "@codeant-ai review;@cursor review;@cursor review;" "$(posted)"

echo "== full: a failed post releases its claim =="
reset "$(tier_json present full)"
export FIXTURE_POST_FAIL="@cursor review"
run
check_eq "cursor trigger-failed" "trigger-failed" "$(st cursor)"
check_eq "the claim was released" "0" "$(ledger cursor)"
check_eq "codeant still posted and claimed" "1" "$(ledger codeant)"

echo "== full: the CodeRabbit fallback stays behind the hourly cap =="
reset "$(tier_json present full)"
jq -cn --arg at "$(ago 2400)" '[{user: {login: "me"}, body: "@codeant-ai review", created_at: $at, updated_at: $at}]' > "$FX/comments.json"
export FIXTURE_CR_CAPPED=1
run
check_eq "CodeAnt silent 40 min, but the CR cap is hit: skipped-rate-cap" "skipped-rate-cap" "$(st coderabbit)"
export FIXTURE_CR_CAPPED=""
run
check_eq "cap clear: the fallback triggers" "triggered" "$(st coderabbit)"
check_eq "  @coderabbitai full review posted" "yes" "$(grep -qFx '@coderabbitai full review' "$POSTED_LOG" && echo yes || echo no)"

echo "== --dry-run evaluates, never claims =="
reset "$(tier_json present full)"
run --dry-run
check_eq "codeant and cursor would trigger" "dry-run-would-trigger:dry-run-would-trigger" "$(st codeant):$(st cursor)"
check_eq "nothing posted" "" "$(posted)"
check_eq "nothing claimed" "null" "$(ledger codeant)"

echo "== an unusable helper answer defers everything =="
reset "$(tier_json present full)"
printf '#!/usr/bin/env bash\necho garbage\n' > "$TMP/bad-helper.sh"; chmod +x "$TMP/bad-helper.sh"
PREFLIGHT_TRIGGERS_ALLOWED_SH="$TMP/bad-helper.sh" run
check_eq "every reviewer skipped-tier-deferred" "skipped-tier-deferred,skipped-tier-deferred,skipped-tier-deferred,skipped-tier-deferred" "$(statuses)"
check_eq "nothing posted" "" "$(posted)"

echo
echo "== summary: $PASS passed, $FAIL failed =="
[[ "$FAIL" -eq 0 ]] || exit 1
echo "OK: pr-preflight.sh tier-aware trigger tests passed"
