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
cp "$REPO_ROOT/.claude/scripts/lib/gh-viewer.sh" "$STUB_DIR/lib/gh-viewer.sh"
export VIEWER_CACHE_DIR="$TMP/viewer-cache-es"
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
if [[ "\${1:-}" == "auth" ]]; then exit 1; fi
if [[ "\${1:-}" == "api" && "\${2:-}" == "user" ]]; then echo "\${FAKE_VIEWER:-octo}"; exit 0; fi
if [[ "\${1:-}" == "api" && "\${2:-}" == "repos/$OWNER/$REPO/pulls/$PR_NUM" ]]; then
  echo x >> "$TMP/pulls-reads"
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

seed() { # [head] [base] [allow] [rc] [json] [viewer]
  rm -rf "$GATE_CACHE_DIR"
  gate_cache_save "$OWNER/$REPO" "$PR_NUM" "${1:-$HEAD_SHA}" "${2:-$BASE_SHA}" "${3:-0}" "${4:-0}" \
    "${5:-$(jq -c --arg h "${1:-$HEAD_SHA}" '.head_sha = $h' <<<"$GATE_MET_JSON")}" "${6:-octo}" \
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

echo "== (g3b): the result is bound to the viewer login whose authorship check produced it =="
seed;                                  FAKE_VIEWER="someone-else" run_case "g3b other viewer now" no_reviewer 1
seed "$HEAD_SHA" "$BASE_SHA" 0 0 "" "someone-else"; run_case "g3b saved under another viewer" no_reviewer 1
seed;                                  mutate 'del(.viewer)';                run_case "g3b no viewer recorded" no_reviewer 1
rm -rf "$GATE_CACHE_DIR"
gate_cache_save "$OWNER/$REPO" "$PR_NUM" "$HEAD_SHA" "$BASE_SHA" 0 0 "$GATE_MET_JSON" "" && echo "FAIL — saved without a viewer" && exit 1
check_eq "(g3b) nothing saved without a viewer" "0" "$([[ -e "$CACHE_FILE" ]] && echo 1 || echo 0)"

echo "== (g3c): no saved file -> no live SHA read at all =="
rm -rf "$GATE_CACHE_DIR"; rm -f "$TMP/pulls-reads"
run_case "g3c nothing saved" no_reviewer 1
check_eq "(g3c) no pulls/N read when nothing is saved" "0" "$([[ -f "$TMP/pulls-reads" ]] && wc -l < "$TMP/pulls-reads" | tr -d " " || echo 0)"

echo "== (g3d): an unreadable saved file -> no live SHA read, live gate run =="
seed; chmod 000 "$CACHE_FILE"; rm -f "$TMP/pulls-reads"
run_case "g3d unreadable" no_reviewer 1
check_eq "(g3d) no pulls/N read for an unreadable file" "0" "$([[ -f "$TMP/pulls-reads" ]] && wc -l < "$TMP/pulls-reads" | tr -d " " || echo 0)"
chmod 600 "$CACHE_FILE" 2>/dev/null || true

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
echo "$*|T=${GH_TOKEN:-}|E=${GH_ENTERPRISE_TOKEN:-}|H=${GH_HOST:-}" >> "$U_CALLS"
echo "$0 $*" >> "$U_ARGV"
case "$*" in
  "auth token --hostname "*) [[ -n "${U_STORED:-}" ]] && { echo "$U_STORED"; exit 0; }; exit 1 ;;
  "api user --jq .login") [[ -n "${U_FAIL:-}" ]] && exit 1; echo "${U_LOGIN:-octo}" ;;
esac
STUB
chmod +x "$UBIN/gh"
# An `env` spy: any call that carries a credential in env's own arguments is logged.
cat > "$UBIN/env" <<'SPY'
#!/usr/bin/env bash
echo "env $*" >> "$U_ARGV"
exec /usr/bin/env "$@"
SPY
chmod +x "$UBIN/env"
export U_ARGV="$TMP/u-argv" U_CALLS="$TMP/u-calls" VIEWER_CACHE_DIR="$TMP/viewer-cache" GH_CONFIG_DIR="$TMP/ghcfg"
mkdir -p "$GH_CONFIG_DIR"
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
echo "-- bound to the captured credential and host --"
export GH_TOKEN="tok-A" U_LOGIN="octo"; rm -f "$U_CALLS"; rm -rf "$VIEWER_CACHE_DIR"
PATH="$UBIN:$PATH" gh_viewer_login >/dev/null
check_eq "(u7) the live request carries the captured token" "1" "$(grep -c 'api user.*|T=tok-A|' "$U_CALLS")"
unset GH_TOKEN; export U_STORED="stored-tok"; rm -f "$U_CALLS"; rm -rf "$VIEWER_CACHE_DIR"
PATH="$UBIN:$PATH" gh_viewer_login >/dev/null
check_eq "(u7) a stored credential is pinned onto the request too" "1" "$(grep -c 'api user.*|T=stored-tok|' "$U_CALLS")"
unset U_STORED
export GH_TOKEN="tok-A" GH_HOST="ghe.example.com" GH_ENTERPRISE_TOKEN="ent-1" U_LOGIN="ent-user"; rm -f "$U_CALLS"; rm -rf "$VIEWER_CACHE_DIR"
r6="$(PATH="$UBIN:$PATH" gh_viewer_login)"
check_eq "(u8) enterprise host answers with its own login" "ent-user" "$r6"
check_eq "(u8) the request is pinned to the enterprise token and host" "1" "$(grep -c 'api user.*|E=ent-1|H=ghe.example.com' "$U_CALLS")"
unset GH_HOST GH_ENTERPRISE_TOKEN; export U_LOGIN="dotcom-user"; rm -f "$U_CALLS"
r7="$(PATH="$UBIN:$PATH" gh_viewer_login)"
check_eq "(u8) the github.com entry never answers for the enterprise host (and vice versa)" "dotcom-user" "$r7"
export GH_HOST="ghe.example.com" GH_ENTERPRISE_TOKEN="ent-2" U_LOGIN="ent-user-2"
r8="$(PATH="$UBIN:$PATH" gh_viewer_login)"
check_eq "(u8) a different enterprise token never serves the old login" "ent-user-2" "$r8"
unset GH_HOST GH_ENTERPRISE_TOKEN
echo "-- *.ghe.com uses GH_TOKEN, not GH_ENTERPRISE_TOKEN --"
export GH_HOST="tenant.ghe.com" GH_TOKEN="fake-ghe-1" GH_ENTERPRISE_TOKEN="fake-ent-const" U_LOGIN="ghe-user-1"; rm -rf "$VIEWER_CACHE_DIR"
r9="$(PATH="$UBIN:$PATH" gh_viewer_login)"
export GH_TOKEN="fake-ghe-2" U_LOGIN="ghe-user-2"
r10="$(PATH="$UBIN:$PATH" gh_viewer_login)"
check_eq "(u9) changing GH_TOKEN on a ghe.com host changes the answer even if GH_ENTERPRISE_TOKEN is constant" "ghe-user-1 ghe-user-2" "$r9 $r10"
unset GH_HOST GH_ENTERPRISE_TOKEN
echo "-- unset GH_HOST with a single enterprise host configured -> nothing cached, plain live call --"
printf 'ghe.example.com:\n    user: x\n' > "$GH_CONFIG_DIR/hosts.yml"
export GH_TOKEN="fake-dot" U_LOGIN="octo"; rm -rf "$VIEWER_CACHE_DIR"; rm -f "$U_CALLS"
PATH="$UBIN:$PATH" gh_viewer_login >/dev/null; PATH="$UBIN:$PATH" gh_viewer_login >/dev/null
check_eq "(u10) no host this helper can name -> two live lookups, nothing cached" "0" "$([[ -d "$VIEWER_CACHE_DIR" ]] && ls "$VIEWER_CACHE_DIR" | wc -l | tr -d ' ' || echo 0)"
printf 'github.com:\n    user: x\n' > "$GH_CONFIG_DIR/hosts.yml"
rm -f "$U_CALLS"; PATH="$UBIN:$PATH" gh_viewer_login >/dev/null; PATH="$UBIN:$PATH" gh_viewer_login >/dev/null
check_eq "(u10) a sole github.com host is named and cached (one live lookup)" "1" "$(grep -c 'api user' "$U_CALLS")"
rm -f "$GH_CONFIG_DIR/hosts.yml"
echo "-- the credential never reaches an argument vector --"
export GH_TOKEN="fake-secret-token-123" U_LOGIN="octo"; rm -rf "$VIEWER_CACHE_DIR"; rm -f "$U_ARGV"
PATH="$UBIN:$PATH" gh_viewer_login >/dev/null
export GH_HOST="ghe.example.com" GH_ENTERPRISE_TOKEN="fake-secret-ent-456"; rm -rf "$VIEWER_CACHE_DIR"
PATH="$UBIN:$PATH" gh_viewer_login >/dev/null
unset GH_HOST GH_ENTERPRISE_TOKEN
check_eq "(u11) stubbed gh calls carry no token in their arguments" "0" "$(grep -c 'fake-secret' "$U_ARGV" || true)"
check_eq "(u11) ...and the gh calls were really made" "1" "$([[ $(wc -l < "$U_ARGV") -ge 2 ]] && echo 1 || echo 0)"
check_eq "(u11) no token text in the cache dir (names or contents)" "0" "$( { ls "$VIEWER_CACHE_DIR"; cat "$VIEWER_CACHE_DIR"/*; } 2>/dev/null | grep -c 'fake-secret' || true)"
export GH_TOKEN="tok-A" U_LOGIN="octo"
export GH_TOKEN="tok-A" U_LOGIN="octo"
touch -t 200001010000 "$VIEWER_CACHE_DIR"/*
rm -f "$U_CALLS"; PATH="$UBIN:$PATH" gh_viewer_login >/dev/null
check_eq "(u6) an old cache file is not trusted" "1" "$(ucount)"

finish_escalate_review_tests "gate result reuse"
