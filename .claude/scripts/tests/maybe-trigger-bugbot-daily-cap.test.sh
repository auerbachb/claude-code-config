#!/usr/bin/env bash
# Offline tests for the account daily-cap BugBot skip in maybe-trigger-ai-review.sh
# (issue #1812).
# catalog: tests — Tests the account daily-cap `@cursor review` skip in `maybe-trigger-ai-review.sh` — over/ok/unknown, dry-run reporting, the open cursor step, and that the tier and refused-HEAD skips still win
#
# WHAT IS UNDER TEST
#   Before posting `@cursor review`, the script asks review-daily-cap.sh whether
#   one more BugBot review fits under the account's daily cap. Only a validated
#   `over` skips; `unknown`, a missing helper, or a garbled answer posts. The
#   tier skip (#1728) and the refused-HEAD skip (#1199) are asked first and
#   still win. CodeAnt and Graphite always post.
#
# HOW IT IS OBSERVED
#   The REAL maybe-trigger script runs from a stub SCRIPT_DIR whose
#   review-daily-cap.sh is a stub answering each scenario's JSON and exit code
#   (its own logic is covered by review-daily-cap.test.sh). The gh stub appends
#   every posted comment body to $POSTED and serves a refusal only when a
#   scenario asks for one.

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
check_contains() {
  local desc="$1" needle="$2" hay="$3"
  if [[ "$hay" == *"$needle"* ]]; then
    PASS=$((PASS + 1)); echo "ok   — $desc"
  else
    FAIL=$((FAIL + 1)); echo "FAIL — $desc (no '$needle' in: ${hay:0:300})"
  fi
}

PR_NUM="99561"
HEAD_SHA="deadbeef0000000000000000000000000000abcf"

# ---- stub SCRIPT_DIR ---------------------------------------------------------
STUB_DIR="$TMP/scripts"
mkdir -p "$STUB_DIR/lib"
for f in maybe-trigger-ai-review.sh session-state.sh state-lock.sh bugbot-tier-excluded.sh; do
  cp "$REPO_ROOT/.claude/scripts/$f" "$STUB_DIR/"
done
cp "$REPO_ROOT/.claude/scripts/lib/repo-normalizer.sh" "$REPO_ROOT/.claude/scripts/lib/ts-normalizer.sh" "$STUB_DIR/lib/"

# The refusal guard's own logic is maybe-trigger-bugbot-suppression.test.sh's
# job; here it only has to say "refused" when a scenario asks.
cat > "$STUB_DIR/bugbot-refused-head.sh" <<'STUB'
#!/usr/bin/env bash
[[ -n "${FIXTURE_REFUSED:-}" ]]
STUB
# Tier resolver: answers FIXTURE_GATE (full unless a scenario says otherwise).
cat > "$STUB_DIR/review-tier.sh" <<'STUB'
#!/usr/bin/env bash
printf '{"policy":"present","gate":"%s","tier":"t","source":"base:main","error":null,"matches":[]}\n' "${FIXTURE_GATE:-full}"
STUB
# The cap: --rate prints FIXTURE_RATE; a check logs its args, prints
# FIXTURE_CAP_OUT, and exits FIXTURE_CAP_RC.
cat > "$STUB_DIR/review-daily-cap.sh" <<'STUB'
#!/usr/bin/env bash
if [[ " $* " == *" --rate "* ]]; then printf '%s\n' "${FIXTURE_RATE:-1.58}"; exit 0; fi
printf '%s\n' "$*" >> "$CAP_CALLS"
printf '%s\n' "$FIXTURE_CAP_OUT"
exit "${FIXTURE_CAP_RC:-0}"
STUB
printf '#!/usr/bin/env bash\necho 3\n'   > "$STUB_DIR/cycle-count.sh"
printf '#!/usr/bin/env bash\necho 500\n' > "$STUB_DIR/complexity-score.sh"
chmod +x "$STUB_DIR"/*.sh
export CAP_CALLS="$TMP/cap-calls"

# ---- gh stub -------------------------------------------------------------------
STUB_BIN="$TMP/bin"
mkdir -p "$STUB_BIN"
cat > "$STUB_BIN/gh" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
sub="${1-}"; shift || true
case "$sub" in
  pr)
    case "${1-}" in
      view) echo "$FIXTURE_HEAD_SHA"; exit 0 ;;
      comment)
        prev=""
        for a in "$@"; do
          if [[ "$prev" == "--body" ]]; then
            if [[ -n "${FIXTURE_POST_FAIL:-}" && "$a" == "$FIXTURE_POST_FAIL" ]]; then exit 1; fi
            echo "$a" >> "$POSTED"; exit 0
          fi
          prev="$a"
        done
        exit 0 ;;
    esac
    exit 0 ;;
  api) echo "[]" ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$STUB_BIN/gh"
export PATH="$STUB_BIN:$PATH"
export FIXTURE_HEAD_SHA="$HEAD_SHA"

cap_json() {   # <status> [spent]
  local spent="${2:-9.48}"
  [[ "$1" == "unknown" ]] && spent=null
  printf '{"platform":"bugbot","date":"2026-10-08","spent_usd":%s,"add_usd":1.58,"cap_usd":10,"status":"%s"}' "$spent" "$1"
}

setup() { # <cap stdout> <cap exit code>
  rm -f "$HOME/.claude/session-state.json"
  export FIXTURE_CAP_OUT="$1" FIXTURE_CAP_RC="$2"
  export FIXTURE_GATE="full" FIXTURE_REFUSED="" FIXTURE_POST_FAIL="" FIXTURE_RATE="1.58"
  export POSTED="$TMP/posted.txt"
  : > "$POSTED"; : > "$CAP_CALLS"
}

JSON_OUT=""
ERR_OUT=""
run_script() {
  JSON_OUT="$( cd "$REPO_ROOT" && bash "$STUB_DIR/maybe-trigger-ai-review.sh" "$PR_NUM" --json "$@" 2>"$TMP/err" )"
  local rc=$?
  ERR_OUT="$(cat "$TMP/err")"
  return $rc
}
run_text() {
  JSON_OUT="$( cd "$REPO_ROOT" && bash "$STUB_DIR/maybe-trigger-ai-review.sh" "$PR_NUM" "$@" 2>"$TMP/err" )"
}
posted_cursor() { grep -cFx "@cursor review" "$POSTED" 2>/dev/null | tr -d ' '; }
posted_all()    { tr '\n' ';' < "$POSTED"; }
read_step() {
  ( cd "$REPO_ROOT" && "$STUB_DIR/session-state.sh" \
      --get ".prs[\"$PR_NUM\"].ai_review_trigger_steps.$1" 2>/dev/null )
}

############################################################################
echo "== (a) dry run, full tier, cap over -> bugbot_skipped: daily_cap with the tally =="
setup "$(cap_json over)" 1
run_script --dry-run; RC=$?
check_eq "exit 0" "0" "$RC"
check_eq "posted nothing" "" "$(posted_all)"
check_eq "bugbot_skipped.reason" "daily_cap" "$(jq -r '.bugbot_skipped.reason' <<<"$JSON_OUT")"
check_eq "bugbot_skipped.gate is null" "null" "$(jq -c '.bugbot_skipped.gate' <<<"$JSON_OUT")"
check_eq "bugbot_skipped.tally is the helper's line" "$(cap_json over)" "$(jq -c '.bugbot_skipped.tally' <<<"$JSON_OUT")"
check_eq "bugbot_daily_cap carries the tally" "over" "$(jq -r '.bugbot_daily_cap.status' <<<"$JSON_OUT")"
check_eq "the cap was asked for bugbot with the --rate figure" "bugbot --add-usd 1.58;" "$(tr '\n' ';' < "$CAP_CALLS")"
run_text --dry-run
check_contains "text dry run names the cap and the tally" 'daily cap: $9.48 of $10.00 spent today' "$JSON_OUT"
check_contains "  and still posts codeant + graphite" "would post 2 separate comments (codeant, graphite" "$JSON_OUT"

echo "== (b) dry run, full tier, cap ok -> the BugBot nudge as today =="
setup "$(cap_json ok 3.16)" 0
run_script --dry-run
check_eq "bugbot_skipped null" "null" "$(jq -c '.bugbot_skipped' <<<"$JSON_OUT")"
check_eq "bugbot_daily_cap reports ok" "ok" "$(jq -r '.bugbot_daily_cap.status' <<<"$JSON_OUT")"
run_text --dry-run
check_contains "text dry run: all three" "would post 3 separate comments (codeant, cursor, graphite)" "$JSON_OUT"

############################################################################
echo "== (c) real run, cap over -> no @cursor review; CodeAnt + Graphite post; step left open =="
setup "$(cap_json over)" 1
run_script; RC=$?
check_eq "exit 0" "0" "$RC"
check_eq "no @cursor review" "0" "$(posted_cursor)"
check_eq "CodeAnt and Graphite posted, in order" "@codeant-ai review;@graphite-app re-review;" "$(posted_all)"
check_eq "--json bugbot_skipped.reason" "daily_cap" "$(jq -r '.bugbot_skipped.reason' <<<"$JSON_OUT")"
check_eq "--json bugbot_skipped.tally.spent_usd" "9.48" "$(jq -r '.bugbot_skipped.tally.spent_usd' <<<"$JSON_OUT")"
check_eq "--json status triggered" "triggered" "$(jq -r '.status' <<<"$JSON_OUT")"
check_contains "stderr says why" "skipping @cursor review — account daily cap" "$ERR_OUT"
# A failed Graphite post keeps the steps record, the only state a retry reads.
setup "$(cap_json over)" 1
export FIXTURE_POST_FAIL="@graphite-app re-review"
run_script; RC=$?
check_eq "run failed at the graphite step" "5" "$RC"
check_eq "cursor step NOT recorded (the cap is a daily tally, not a HEAD fact)" "false" "$(read_step cursor)"
echo "== (c2) the cap clears before the retry -> the resumed run posts @cursor review once =="
export FIXTURE_POST_FAIL="" FIXTURE_CAP_OUT="$(cap_json ok 3.16)" FIXTURE_CAP_RC=0
run_script; RC=$?
check_eq "retry exits 0" "0" "$RC"
check_eq "@cursor review posted once" "1" "$(posted_cursor)"
check_eq "codeant not re-posted" "1" "$(grep -cFx "@codeant-ai review" "$POSTED" | tr -d ' ')"

echo "== (d) real run, cap ok -> all three, as today =="
setup "$(cap_json ok 3.16)" 0
run_script
check_eq "all three nudges, in order" "@codeant-ai review;@cursor review;@graphite-app re-review;" "$(posted_all)"
check_eq "bugbot_skipped null" "null" "$(jq -c '.bugbot_skipped' <<<"$JSON_OUT")"
check_eq "bugbot_daily_cap ok" "ok" "$(jq -r '.bugbot_daily_cap.status' <<<"$JSON_OUT")"

############################################################################
echo "== (e) FAILS OPEN: unknown -> posts, and the unknown is visible =="
setup "$(cap_json unknown)" 0
run_script
check_eq "@cursor review posted" "1" "$(posted_cursor)"
check_eq "bugbot_skipped null" "null" "$(jq -c '.bugbot_skipped' <<<"$JSON_OUT")"
check_eq "bugbot_daily_cap.status unknown" "unknown" "$(jq -r '.bugbot_daily_cap.status' <<<"$JSON_OUT")"
check_eq "bugbot_daily_cap.spent_usd null" "null" "$(jq -r '.bugbot_daily_cap.spent_usd' <<<"$JSON_OUT")"
check_contains "stderr says the cap is unknown" "daily cap is unknown today" "$ERR_OUT"

echo "== (f) FAILS OPEN: the helper is missing -> posts =="
setup "$(cap_json over)" 1
mv "$STUB_DIR/review-daily-cap.sh" "$TMP/cap.bak"
run_script
mv "$TMP/cap.bak" "$STUB_DIR/review-daily-cap.sh"
check_eq "@cursor review posted despite an over answer nobody could ask" "1" "$(posted_cursor)"
check_eq "bugbot_daily_cap null" "null" "$(jq -c '.bugbot_daily_cap' <<<"$JSON_OUT")"
check_contains "stderr names the missing helper" "DEGRADED: review-daily-cap.sh not found" "$ERR_OUT"

echo "== (g) FAILS OPEN: garbled answers -> posts =="
setup "not json" 1
run_script
check_eq "non-JSON output: posts" "1" "$(posted_cursor)"
setup "$(cap_json over)" 0
run_script
check_eq "status over but exit 0 (they disagree): posts" "1" "$(posted_cursor)"
check_eq "  and reports no skip" "null" "$(jq -c '.bugbot_skipped' <<<"$JSON_OUT")"
check_eq "  and reports the cap as unknown, never over beside a post" "unknown" "$(jq -r '.bugbot_daily_cap.status' <<<"$JSON_OUT")"
setup "$(cap_json over)" 3
run_script
check_eq "exit 3 (not a cap answer): posts" "1" "$(posted_cursor)"
setup '{"status":"maybe"}' 1
run_script
check_eq "an unknown status word: posts" "1" "$(posted_cursor)"

############################################################################
echo "== (h) precedence: a tier skip wins over the cap, and the cap is never asked =="
setup "$(cap_json over)" 1
export FIXTURE_GATE="ci-only"
run_script
check_eq "reason review_tier" "review_tier" "$(jq -r '.bugbot_skipped.reason' <<<"$JSON_OUT")"
check_eq "the cap was not consulted" "" "$(tr '\n' ';' < "$CAP_CALLS")"
check_eq "bugbot_daily_cap null" "null" "$(jq -c '.bugbot_daily_cap' <<<"$JSON_OUT")"
setup "$(cap_json over)" 1
export FIXTURE_GATE="ci-only"
run_script --dry-run
check_eq "dry run: still review_tier" "review_tier" "$(jq -r '.bugbot_skipped.reason' <<<"$JSON_OUT")"
check_eq "dry run: the cap was not consulted either" "" "$(tr '\n' ';' < "$CAP_CALLS")"

echo "== (i) precedence: a refused HEAD wins over the cap =="
setup "$(cap_json over)" 1
export FIXTURE_REFUSED=1
run_script
check_eq "no @cursor review" "0" "$(posted_cursor)"
check_eq "reason refused_head" "refused_head" "$(jq -r '.bugbot_skipped.reason' <<<"$JSON_OUT")"
setup "$(cap_json over)" 1
export FIXTURE_REFUSED=1 FIXTURE_POST_FAIL="@graphite-app re-review"
run_script
check_eq "the refusal (a HEAD fact) still marks the step handled, unlike the cap" "true" "$(read_step cursor)"

echo
echo "== summary: $PASS passed, $FAIL failed =="
[[ "$FAIL" -eq 0 ]] || exit 1
echo "OK: maybe-trigger-ai-review.sh daily-cap BugBot skip tests passed"
