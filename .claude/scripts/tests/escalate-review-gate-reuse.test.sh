#!/usr/bin/env bash
# Offline tests: escalate-review.sh reuses polling-state-gate.sh's merge-gate result
# only on a fully fail-closed match (issue #2442, slice of #2421).
# catalog: tests — Same-cycle merge-gate result reuse in `escalate-review.sh` and `lib/gate-result-cache.sh`: hit, every invalidation case, corrupt-file fallback, stand-alone run, authenticated-user memo
# Shared fixtures live in tests/lib/escalate-review-fixtures.sh. No test calls GitHub.
#
# Every scenario reaches override_gate_met (the one place escalate-review.sh runs
# merge-gate.sh), with a merge-gate stub that counts its live runs and whose LIVE
# answer is "not met". So:
#   - STATUS=gate_met + 0 live runs  => the saved result was reused;
#   - STATUS=no_reviewer + 1 live run => the saved result was refused and the gate
#     ran live; the saved (met) data never produced a verdict.
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/escalate-review-fixtures.sh
source "$TEST_DIR/lib/escalate-review-fixtures.sh"

mkdir -p "$STUB_DIR/lib"
cp "$REPO_ROOT/.claude/scripts/lib/gate-result-cache.sh" "$STUB_DIR/lib/gate-result-cache.sh"
export GATE_CACHE_DIR="$TMP/gate-cache"
export GATE_CACHE_TTL=60

BASE_SHA="bbbbbbbb0000000000000000000000000000bbbb"
OTHER_SHA="cccccccc0000000000000000000000000000cccc"
MG_RUNS="$TMP/mg-runs"

cat > "$STUB_DIR/merge-gate.sh" <<STUB
#!/usr/bin/env bash
echo run >> "$MG_RUNS"
if [[ -n "\${MG_LIVE_MET:-}" ]]; then printf '{"met":true,"no_review_override":{"applied":true}}\n'; exit 0; fi
printf '{"met":false,"no_review_override":{"applied":false}}\n'
exit 1
STUB
chmod +x "$STUB_DIR/merge-gate.sh"

OVR_BIN="$TMP/ovr-bin"
mkdir -p "$OVR_BIN"
cat > "$OVR_BIN/gh" <<STUB
#!/usr/bin/env bash
if [[ "\${1:-}" == "repo" && "\${2:-}" == "view" ]]; then echo "$OWNER/$REPO"; exit 0; fi
if [[ "\${1:-}" == "api" && "\${2:-}" == "repos/$OWNER/$REPO/pulls/$PR_NUM" ]]; then
  [[ -n "\${FAKE_PULLS_FAIL:-}" ]] && exit 1
  echo "$OWNER/$REPO \${FAKE_LIVE_HEAD:-$HEAD_SHA} \${FAKE_LIVE_BASE:-$BASE_SHA}"; exit 0
fi
exec "$STUB_BIN/gh" "\$@"
STUB
chmod +x "$OVR_BIN/gh"

GATE_MET_JSON="$(jq -cn --argjson p "$PR_NUM" --arg h "$HEAD_SHA" --arg or "$OWNER/$REPO" \
  '{pr_number:$p, owner_repo:$or, met:true, head_sha:$h, missing:[], no_review_override:{applied:true}}')"

# shellcheck source=../lib/gate-result-cache.sh
. "$REPO_ROOT/.claude/scripts/lib/gate-result-cache.sh"
CACHE_FILE="$(gate_cache_file "$OWNER/$REPO" "$PR_NUM")"

seed() { # [head] [base] [allow] [rc] [json]
  rm -rf "$GATE_CACHE_DIR"
  gate_cache_save "$OWNER/$REPO" "$PR_NUM" "${1:-$HEAD_SHA}" "${2:-$BASE_SHA}" "${3:-0}" "${4:-0}" \
    "${5:-$(jq -c --arg h "${1:-$HEAD_SHA}" '.head_sha = $h' <<<"$GATE_MET_JSON")}" \
    || { echo "FAIL — could not seed the saved gate result"; exit 1; }
}
mutate() { # jq filter over the saved file
  jq -c "$1" "$CACHE_FILE" > "$CACHE_FILE.new" && mv "$CACHE_FILE.new" "$CACHE_FILE"
}

# <label> <expected STATUS> <expected live gate runs>
run_case() {
  local label="$1" want="$2" runs="$3" out rc=0
  rm -f "$MG_RUNS"
  reset_state
  write_commits "$(ts_seconds_ago 7200)"
  write_state "[]" "[]" "[]" "[]"
  out="$(PATH="$OVR_BIN:$PATH" run_script_raw 2>/dev/null)" || rc=$?
  check_eq "($label) exit 0" 0 "$rc"
  check_eq "($label) verdict" "STATUS=$want" "$out"
  check_eq "($label) live merge-gate runs" "$runs" "$( [[ -f "$MG_RUNS" ]] && wc -l < "$MG_RUNS" | tr -d ' ' || echo 0 )"
}

echo "== (g1): matching fresh saved result -> reused, no live gate run =="
seed
run_case g1 gate_met 0

echo "== (g2): stand-alone run, nothing saved -> live gate run, as today =="
rm -rf "$GATE_CACHE_DIR"
run_case g2 no_reviewer 1

echo "== (g3): invalidation — each miss runs the gate live and never uses the old data =="
seed "$OTHER_SHA";                     run_case "g3 saved HEAD differs"      no_reviewer 1
seed "$HEAD_SHA" "$OTHER_SHA";         run_case "g3 saved base differs"      no_reviewer 1
seed;                                  FAKE_LIVE_BASE="$OTHER_SHA" run_case "g3 live base moved" no_reviewer 1
seed;                                  FAKE_LIVE_HEAD="$OTHER_SHA" run_case "g3 live HEAD moved" no_reviewer 1
seed;                                  mutate '.pr = 1';                     run_case "g3 other PR"       no_reviewer 1
seed;                                  mutate '.owner_repo = "other/repo"';  run_case "g3 other repo"     no_reviewer 1
seed;                                  mutate '.saved_epoch -= 61';          run_case "g3 stale (61s)"    no_reviewer 1
seed;                                  mutate '.saved_epoch += 600';         run_case "g3 from the future" no_reviewer 1
seed "$HEAD_SHA" "$BASE_SHA" 1;        run_case "g3 saved under --allow-nonauthor" no_reviewer 1
seed;                                  mutate '.rc = 2';                     run_case "g3 gate exited 2 (error)" no_reviewer 1
seed;                                  mutate '.rc = 1';                     run_case "g3 exit 1 but body says met" no_reviewer 1
seed;                                  mutate '.gate.met = false';           run_case "g3 exit 0 but body says unmet" no_reviewer 1
seed;                                  FAKE_PULLS_FAIL=1 run_case "g3 live SHA read fails" no_reviewer 1

echo "== (g4): boundary — a 50s-old result (margin for run time) is still reused =="
seed; mutate '.saved_epoch -= 50'
run_case "g4 50s old" gate_met 0

echo "== (g4b): an oversized or odd GATE_CACHE_TTL never extends the life past 60s =="
seed; mutate '.saved_epoch -= 61'; GATE_CACHE_TTL=3600 run_case "g4b ttl=3600, 61s old" no_reviewer 1
seed; mutate '.saved_epoch -= 61'; GATE_CACHE_TTL=99999999999999 run_case "g4b huge ttl" no_reviewer 1
seed; mutate '.saved_epoch -= 61'; GATE_CACHE_TTL=abc run_case "g4b non-numeric ttl -> default 60" no_reviewer 1
seed; GATE_CACHE_TTL=abc run_case "g4b non-numeric ttl, fresh result reused" gate_met 0
seed; GATE_CACHE_TTL=0 run_case "g4b ttl=0 -> no reuse" no_reviewer 1
seed; mutate '.saved_epoch -= 40'; GATE_CACHE_TTL=30 run_case "g4b smaller ttl honoured" no_reviewer 1

echo "== (g5): corrupt / partial saved result -> live gate run, never a pass =="
seed; printf '{"schema":1,"saved_epoch":' > "$CACHE_FILE";           run_case "g5 truncated file" no_reviewer 1
seed; : > "$CACHE_FILE";                                              run_case "g5 empty file"     no_reviewer 1
seed; printf 'not json at all\n' > "$CACHE_FILE";                     run_case "g5 garbage"        no_reviewer 1
seed; mutate 'del(.gate.met)';                                        run_case "g5 no .met"        no_reviewer 1
seed; mutate '.gate.met = "true"';                                    run_case "g5 .met not boolean" no_reviewer 1
seed; mutate 'del(.gate.missing)';                                    run_case "g5 no .missing"    no_reviewer 1
seed; mutate 'del(.rc)';                                              run_case "g5 no rc"          no_reviewer 1
seed; mutate '.schema = 2';                                           run_case "g5 unknown schema" no_reviewer 1
seed; mutate '.gate = []';                                            run_case "g5 gate not object" no_reviewer 1
seed; chmod 000 "$CACHE_FILE";                                        run_case "g5 unreadable"     no_reviewer 1
chmod 600 "$CACHE_FILE" 2>/dev/null || true

echo "== (g6): a saved UNMET result (the waiting cycle) is reused with no second gate run =="
UNMET_JSON="$(jq -c '.met=false | .no_review_override.applied=false | .missing=["no review"]' <<<"$GATE_MET_JSON")"
seed "$HEAD_SHA" "$BASE_SHA" 0 1 "$UNMET_JSON"
run_case "g6 unmet reused" no_reviewer 0
echo "-- the same unmet result is refused under every invalidation case --"
seed "$HEAD_SHA" "$BASE_SHA" 0 1 "$UNMET_JSON"; mutate '.saved_epoch -= 61'; run_case "g6 stale unmet" no_reviewer 1
seed "$HEAD_SHA" "$BASE_SHA" 0 1 "$UNMET_JSON"; FAKE_LIVE_HEAD="$OTHER_SHA" run_case "g6 unmet, HEAD moved" no_reviewer 1
seed "$HEAD_SHA" "$BASE_SHA" 0 1 "$UNMET_JSON"; FAKE_LIVE_BASE="$OTHER_SHA" run_case "g6 unmet, base moved" no_reviewer 1
echo "-- straddling the override window: saved unmet, live would now be met --"
# A within-lifetime unmet result can only DELAY gate_met by one cycle; it can
# never turn into a pass, and past the lifetime the live gate answers.
seed "$HEAD_SHA" "$BASE_SHA" 0 1 "$UNMET_JSON"; MG_LIVE_MET=1 run_case "g6 window elapsed inside lifetime: delayed, not wrong" no_reviewer 0
seed "$HEAD_SHA" "$BASE_SHA" 0 1 "$UNMET_JSON"; mutate '.saved_epoch -= 61'; MG_LIVE_MET=1 run_case "g6 window elapsed, result past lifetime: live gate decides" gate_met 1

echo "== (g7): save refuses bad input and a failed write is harmless =="
rm -rf "$GATE_CACHE_DIR"
gate_cache_save "$OWNER/$REPO" "$PR_NUM" "$HEAD_SHA" "$BASE_SHA" 0 0 '{"met":true}' && echo "FAIL — saved an incomplete result" && exit 1
check_eq "(g7) incomplete result not saved" "0" "$([[ -e "$CACHE_FILE" ]] && echo 1 || echo 0)"
gate_cache_save "$OWNER/$REPO" "$PR_NUM" "$OTHER_SHA" "$BASE_SHA" 0 0 "$GATE_MET_JSON" && echo "FAIL — saved a result whose head differs from the snapshot" && exit 1
check_eq "(g7) head mismatch not saved" "0" "$([[ -e "$CACHE_FILE" ]] && echo 1 || echo 0)"
mkdir -p "$TMP/ro" && chmod 500 "$TMP/ro"
GATE_CACHE_DIR="$TMP/ro/x" gate_cache_save "$OWNER/$REPO" "$PR_NUM" "$HEAD_SHA" "$BASE_SHA" 0 0 "$GATE_MET_JSON" && echo "FAIL — claimed a save into an unwritable dir" && exit 1
check_eq "(g7) unwritable dir reports not-saved without printing" "" \
  "$(GATE_CACHE_DIR="$TMP/ro/x" gate_cache_save "$OWNER/$REPO" "$PR_NUM" "$HEAD_SHA" "$BASE_SHA" 0 0 "$GATE_MET_JSON" 2>&1 || true)"
chmod 700 "$TMP/ro"
seed
check_eq "(g7) saved file holds no token-like field" "0" "$(grep -ciE 'token|password|secret' "$CACHE_FILE" || true)"
check_eq "(g7) saved file lives under the cache dir, not a worktree" "$GATE_CACHE_DIR" "$(dirname "$CACHE_FILE")"

echo "== (u): gh-viewer.sh — one user lookup per token, a failed lookup is never cached =="
. "$REPO_ROOT/.claude/scripts/lib/gh-viewer.sh"
UBIN="$TMP/ubin"; mkdir -p "$UBIN"
cat > "$UBIN/gh" <<'STUB'
#!/usr/bin/env bash
echo x >> "$U_CALLS"
case "$*" in
  "auth token") exit 1 ;;
  "api user --jq .login") [[ -n "${U_FAIL:-}" ]] && exit 1; echo "${U_LOGIN:-octo}" ;;
esac
STUB
chmod +x "$UBIN/gh"
export U_CALLS="$TMP/u-calls" VIEWER_CACHE_DIR="$TMP/viewer-cache"
ucount() { [[ -f "$U_CALLS" ]] && grep -c . "$U_CALLS" || echo 0; }
export GH_TOKEN="tok-A"
rm -f "$U_CALLS"
r1="$(PATH="$UBIN:$PATH" gh_viewer_login)"; r2="$(PATH="$UBIN:$PATH" gh_viewer_login)"; r3="$(PATH="$UBIN:$PATH" gh_viewer_login)"
check_eq "(u1) same login every time" "octo octo octo" "$r1 $r2 $r3"
check_eq "(u1) one gh call for three lookups" "1" "$(ucount)"
check_eq "(u2) cache holds only the login" "octo" "$(cat "$VIEWER_CACHE_DIR"/* | tr -d '\n')"
check_eq "(u2) no token in the cache dir" "0" "$(grep -rc 'tok-A' "$VIEWER_CACHE_DIR" | awk -F: '{s+=$2} END{print s+0}')"
export GH_TOKEN="tok-B" U_LOGIN="someone-else"; rm -f "$U_CALLS"
r4="$(PATH="$UBIN:$PATH" gh_viewer_login)"
check_eq "(u3) a different token never serves the old user" "someone-else" "$r4"
check_eq "(u3) ...with its own lookup" "1" "$(ucount)"
export GH_TOKEN="tok-C" U_FAIL=1; rm -f "$U_CALLS"
rc=0; PATH="$UBIN:$PATH" gh_viewer_login >/dev/null || rc=$?
check_eq "(u4) failed lookup fails (no fabricated login)" "1" "$rc"
unset U_FAIL; export U_LOGIN="octo2"; rm -f "$U_CALLS"
r5="$(PATH="$UBIN:$PATH" gh_viewer_login)"
check_eq "(u4) failure was not cached: next call asks again" "octo2" "$r5"
unset GH_TOKEN GITHUB_TOKEN; rm -f "$U_CALLS"
PATH="$UBIN:$PATH" gh_viewer_login >/dev/null; PATH="$UBIN:$PATH" gh_viewer_login >/dev/null
check_eq "(u5) no token readable -> nothing cached (2 lookups + 2 token reads)" "4" "$(ucount)"
export GH_TOKEN="tok-A" U_LOGIN="octo"
touch -t 200001010000 "$VIEWER_CACHE_DIR"/*
rm -f "$U_CALLS"; PATH="$UBIN:$PATH" gh_viewer_login >/dev/null
check_eq "(u6) an old cache file is not trusted" "1" "$(ucount)"

finish_escalate_review_tests "gate result reuse"
