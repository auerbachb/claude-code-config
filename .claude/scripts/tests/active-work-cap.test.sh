#!/usr/bin/env bash
# Tests for active-work-cap.sh — the repo-wide budget for simultaneously
# active coding work (issue #1191).
#
# Every source the script reads is redirected into a temp dir: the chip logs
# via CLAUDE_ACTIVE_WORK_HANDOFF_DIR, session-state via HOME, the cap via a
# throwaway git repo carrying its own .claude/pm-config.md, and GitHub via a
# fake `gh` placed first on PATH. The suite never reads live state and never
# makes a network call.
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SCRIPT="$REPO_ROOT/.claude/scripts/active-work-cap.sh"

TMP_DIR="$(mktemp -d)"
cleanup() { chmod -R u+w "$TMP_DIR" 2>/dev/null || true; rm -rf "$TMP_DIR"; }
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok   — $*"; }

# Isolate from a caller-set override — the default-cap assertions below must
# not silently inherit a different number from the environment.
unset CLAUDE_ACTIVE_WORK_CAP

export CLAUDE_ACTIVE_WORK_HANDOFF_DIR="$TMP_DIR/handoffs"
export HOME="$TMP_DIR/home"
mkdir -p "$CLAUDE_ACTIVE_WORK_HANDOFF_DIR" "$HOME/.claude"

SLUG="testowner/testrepo"

# --- fake gh -----------------------------------------------------------------
# Dispatches on the subcommand pair only, never on the full argument string:
# a fake that matches exact arg order breaks silently the next time a flag is
# added (feedback_test_fake_pitfalls.md). Anything it does not recognise is a
# HARD ERROR, never an empty success — a default branch that absorbs an
# unmatched call lets the code under test fall back and ship green having
# never run the path (feedback_test_stub_absorbs_unmatched_call.md).
BIN="$TMP_DIR/bin"
mkdir -p "$BIN"
cat > "$BIN/gh" <<'GHEOF'
#!/usr/bin/env bash
case "$1 $2" in
  "repo view")
    [[ -n "${GH_FAKE_SLUG:-}" ]] || { echo "fake gh: GH_FAKE_SLUG unset" >&2; exit 1; }
    printf '%s\n' "$GH_FAKE_SLUG" ;;
  "pr list")
    if [[ "${GH_FAKE_PR_FAIL:-0}" == "1" ]]; then
      echo "fake gh: simulated API failure" >&2; exit 1
    fi
    printf '%s\n' "${GH_FAKE_PRS:-[]}" ;;
  "issue list")
    if [[ "${GH_FAKE_ISSUE_FAIL:-0}" == "1" ]]; then
      echo "fake gh: simulated API failure" >&2; exit 1
    fi
    printf '%s' "${GH_FAKE_OPEN_ISSUES:-}" ;;
  *)
    echo "fake gh: unstubbed call: $*" >&2; exit 97 ;;
esac
GHEOF
chmod +x "$BIN/gh"
export PATH="$BIN:$PATH"
export GH_FAKE_SLUG="$SLUG"

# --- fixture helpers ---------------------------------------------------------

# A throwaway git repo so repo-root.sh resolves to a config we control.
FIXTURE_REPO="$TMP_DIR/repo"
mkdir -p "$FIXTURE_REPO/.claude"
git -C "$FIXTURE_REPO" init -q 2>/dev/null || fail "could not init fixture repo"

set_cap_config() {  # $1 = full section body, or empty to remove the file
  if [[ -z "${1:-}" ]]; then
    rm -f "$FIXTURE_REPO/.claude/pm-config.md"
    return
  fi
  printf '# PM Config\n\n## Active work\n\n%s\n\n## Notes\n\nend\n' "$1" \
    > "$FIXTURE_REPO/.claude/pm-config.md"
}

# n open PRs, as the JSON array `gh pr list --json number` returns.
set_open_prs() { GH_FAKE_PRS="$(jq -cn --argjson n "$1" '[range($n) | {number: (.+1000)}]')"; export GH_FAKE_PRS; }

# Newline-separated issue numbers, as `gh issue list --jq '.[].number'` returns.
set_open_issues() { GH_FAKE_OPEN_ISSUES="$1"; export GH_FAKE_OPEN_ISSUES; }

write_chip_log() {  # $1 = log name, $2 = issues[] JSON
  printf '{"issues":%s}\n' "$2" > "$CLAUDE_ACTIVE_WORK_HANDOFF_DIR/issue-maker-$1-log.json"
}

chip_entry() {  # number, repo-slug ("" = no url), status, task-id ("null" = none)
  jq -cn --argjson n "$1" --arg r "$2" --arg s "$3" --arg t "$4" \
    '{number: $n, status: $s,
      chip_task_id: (if $t == "null" then null else $t end)}
     + (if $r == "" then {} else {url: "https://github.com/\($r)/issues/\($n)"} end)'
}

set_pipelines() {  # $1 = active_agents JSON array
  jq -cn --argjson a "$1" --arg k "$SLUG" \
    '{repos: {($k): {prs: {}}}, active_agents: $a}' > "$HOME/.claude/session-state.json"
}

run() { ( cd "$FIXTURE_REPO" && "$SCRIPT" "$@" ); }

# Baseline: nothing anywhere.
set_cap_config ""
set_open_prs 0
set_open_issues ""
set_pipelines '[]'

# --- 1. Default cap when no config and no override ---------------------------
CAP=$(run --cap) || fail "--cap failed with no config present"
[[ "$CAP" == "6" ]] || fail "default cap should be 6, got '$CAP'"
ok "no config and no override resolves the built-in default (6)"

# A repo with no pm-config.md at all is the normal portable case (#1189) and
# must be SILENT — a warning here would fire on every repo that never set one.
ERR=$(run --cap 2>&1 >/dev/null)
[[ -z "$ERR" ]] || fail "absent config should warn nothing, got: '$ERR'"
ok "an absent cap is silent, not a warning"

# --- 2. The knob is read from pm-config (KEY=value, the ## Wave precedent) ----
set_cap_config '```ini
ACTIVE_WORK_CAP=8
```'
CAP=$(run --cap) || fail "--cap failed reading the config"
[[ "$CAP" == "8" ]] || fail "config cap should be 8, got '$CAP'"
ok "ACTIVE_WORK_CAP=8 is read from pm-config"

# --- 3. Test Plan case 1: cap 8, 2 open PRs, 12 fit issues -> FREE == 6 -------
# The 12 candidate issues are the emitter's input, not the script's: the
# script's job is to say how many of them may be offered.
set_open_prs 2
JSON=$(run --json) || fail "--json failed"
FREE=$(printf '%s' "$JSON" | jq -r '.free')
ACTIVE=$(printf '%s' "$JSON" | jq -r '.active')
[[ "$ACTIVE" == "2" ]] || fail "2 open PRs should be 2 active, got '$ACTIVE'"
[[ "$FREE" == "6" ]] || fail "cap 8 minus 2 active should leave 6 free, got '$FREE'"
ok "Test Plan case 1: cap 8, 2 open PRs -> FREE=6 (12 candidates, at most 6 offered)"

# --- 4. Test Plan case 2: the colon form, and the limit follows the config ---
# `active_work_cap: 5` is the shape the ticket used; both must resolve.
set_cap_config 'active_work_cap: 5'
CAP=$(run --cap) || fail "--cap failed on the colon form"
[[ "$CAP" == "5" ]] || fail "colon form should resolve 5, got '$CAP'"
FREE=$(run --free) || fail "--free failed"
[[ "$FREE" == "3" ]] || fail "cap 5 minus 2 active should leave 3 free, got '$FREE'"
ok "Test Plan case 2: active_work_cap: 5 changes the observed limit with no code change"

# --- 5. Prose that NAMES the key is not a value -------------------------------
# pm-config.md documents the knob in bullets directly under it; a parser that
# matched mid-line would read the documentation instead of the setting.
set_cap_config '```ini
ACTIVE_WORK_CAP=7
```

- **ACTIVE_WORK_CAP** — repo-wide cap: your open PRs + chips. Default is 6.'
CAP=$(run --cap) || fail "--cap failed with prose present"
[[ "$CAP" == "7" ]] || fail "prose bullets must not shadow the ini value; got '$CAP'"
ok "a prose bullet naming ACTIVE_WORK_CAP never shadows the real value"

# --- 6. Env override wins over config ----------------------------------------
CAP=$(CLAUDE_ACTIVE_WORK_CAP=2 run --cap) || fail "--cap failed with env override"
[[ "$CAP" == "2" ]] || fail "env override should win, got '$CAP'"
ok "CLAUDE_ACTIVE_WORK_CAP overrides the config value"

# --- 7. Invalid and out-of-range fall back LOUDLY ----------------------------
# Silent fallback is the failure mode this guards: a typo'd knob that reads as
# "the default" with no signal looks identical to never having set one.
for BAD in "abc" "0" "99" "-3"; do
  OUT=$(CLAUDE_ACTIVE_WORK_CAP="$BAD" run --cap 2>"$TMP_DIR/err") || \
    fail "a bad cap ('$BAD') should fall back, not exit non-zero"
  [[ "$OUT" == "6" ]] || fail "bad cap '$BAD' should fall back to 6, got '$OUT'"
  [[ -s "$TMP_DIR/err" ]] || fail "bad cap '$BAD' must warn on stderr, but stderr was empty"
done
ok "unparseable / zero / over-max / negative caps all fall back to 6 and warn"

set_cap_config '```ini
ACTIVE_WORK_CAP=6
```'

# --- 8. Chips count only for THIS repo ---------------------------------------
# The logs are per capture-thread and span every repo worked in; counting them
# all would gate one repo on another's backlog.
write_chip_log "alpha" "[$(chip_entry 11 "$SLUG" open t1),$(chip_entry 12 other/elsewhere open t2)]"
set_open_issues "11
12"
JSON=$(run --json) || fail "--json failed with cross-repo chips"
CHIPS=$(printf '%s' "$JSON" | jq -r '.live_chips')
[[ "$CHIPS" == "1" ]] || fail "only the same-repo chip should count, got '$CHIPS'"
ok "a chip logged against another repo is not counted"

# --- 9. A chip whose issue is CLOSED is finished work, not pending work -------
# chip_task_id is cleared only on an explicit retract, so without this the
# count is a monotonic high-water mark that pins FREE at 0 forever.
set_open_issues "11"   # issue 12 closed; 13 below is closed too
write_chip_log "alpha" "[$(chip_entry 11 "$SLUG" open t1),$(chip_entry 13 "$SLUG" open t3)]"
CHIPS=$(run --json | jq -r '.live_chips') || fail "--json failed"
[[ "$CHIPS" == "1" ]] || fail "a chip for a closed issue must not count, got '$CHIPS'"
ok "a chip survives in the log after its issue closes, but stops counting"

# --- 10. A retracted chip (null task id) never counts -------------------------
write_chip_log "alpha" "[$(chip_entry 11 "$SLUG" open null)]"
CHIPS=$(run --json | jq -r '.live_chips') || fail "--json failed"
[[ "$CHIPS" == "0" ]] || fail "a null chip_task_id must not count, got '$CHIPS'"
ok "a retracted chip (chip_task_id: null) is not live"

# --- 11. Chips are de-duplicated across logs ---------------------------------
# Two capture threads can both hold an entry for the same issue; that is one
# offer, not two.
write_chip_log "alpha" "[$(chip_entry 11 "$SLUG" open t1)]"
write_chip_log "beta"  "[$(chip_entry 11 "$SLUG" open t9)]"
CHIPS=$(run --json | jq -r '.live_chips') || fail "--json failed"
[[ "$CHIPS" == "1" ]] || fail "the same issue in two logs is one chip, got '$CHIPS'"
ok "the same issue offered in two capture logs counts once"
rm -f "$CLAUDE_ACTIVE_WORK_HANDOFF_DIR/issue-maker-beta-log.json"

# --- 12. An unattributable chip is counted, and says so ----------------------
# Over-counting narrows offers (safe); under-counting widens them (the failure
# this script exists to prevent), so an entry with no usable url counts.
write_chip_log "alpha" "[$(chip_entry 11 "" open t1)]"
ERR=$(run --json 2>&1 >/dev/null)
CHIPS=$(run --json 2>/dev/null | jq -r '.live_chips')
[[ "$CHIPS" == "1" ]] || fail "an unattributable chip should be counted, got '$CHIPS'"
[[ "$ERR" == *"no attributable repo url"* ]] || \
  fail "an unattributable chip must be visible on stderr, got: '$ERR'"
ok "a chip with no usable url is counted AND warned about"

# --- 13. Inline pipelines: only those not yet at a PR ------------------------
# An entry gains .pr when its pipeline opens one, at which point the open-PR
# source counts it; counting both would double-count the same work.
write_chip_log "alpha" "[]"
set_open_issues ""
set_open_prs 0
set_pipelines '[{"id":"a1","phase":"A"},{"id":"a2","phase":"B","pr":1234},{"id":"a3","phase":"A","pr":null}]'
JSON=$(run --json) || fail "--json failed with pipelines"
PIPES=$(printf '%s' "$JSON" | jq -r '.inline_pipelines')
[[ "$PIPES" == "2" ]] || fail "only the two agents with no PR should count, got '$PIPES'"
ok "active_agents entries at a PR are excluded; pre-PR ones count"

# --- 14. The three sources sum, and FREE clamps at zero ----------------------
set_open_prs 3
write_chip_log "alpha" "[$(chip_entry 21 "$SLUG" open t1),$(chip_entry 22 "$SLUG" open t2)]"
set_open_issues "21
22"
JSON=$(run --json) || fail "--json failed"
ACTIVE=$(printf '%s' "$JSON" | jq -r '.active')
FREE=$(printf '%s' "$JSON" | jq -r '.free')
[[ "$ACTIVE" == "7" ]] || fail "3 PRs + 2 chips + 2 pipelines should be 7 active, got '$ACTIVE'"
[[ "$FREE" == "0" ]] || fail "active past the cap must clamp FREE to 0, never negative, got '$FREE'"
ok "the three sources sum (3+2+2=7) and FREE clamps at 0 when over cap"

# Derived relationship, asserted rather than the literals: FREE is exactly the
# headroom, so retuning the default can never silently break the arithmetic.
CAPV=$(printf '%s' "$JSON" | jq -r '.cap')
EXPECTED=$(( CAPV - ACTIVE )); (( EXPECTED < 0 )) && EXPECTED=0
[[ "$FREE" == "$EXPECTED" ]] || fail "FREE ($FREE) should equal max(0, cap-active) ($EXPECTED)"
ok "FREE is exactly max(0, CAP - ACTIVE)"

# --- 15. A source that cannot be READ fails loudly, never as zero ------------
# A fabricated zero reads as "nothing active" and would silently uncap the
# gate (feedback_fabricated_sentinel_stable_signature.md).
OUT=$(GH_FAKE_PR_FAIL=1 run --json 2>"$TMP_DIR/err"); RC=$?
[[ $RC -eq 5 ]] || fail "a gh pr list failure should exit 5, got $RC"
[[ -z "$OUT" ]] || fail "a read failure must print nothing on stdout, got: '$OUT'"
grep -q "gh pr list" "$TMP_DIR/err" || fail "the gh failure should name the call on stderr"
ok "a failed open-PR read exits 5 and prints no count"

write_chip_log "alpha" "[$(chip_entry 21 "$SLUG" open t1)]"
set_open_issues "21"
OUT=$(GH_FAKE_ISSUE_FAIL=1 run --json 2>"$TMP_DIR/err"); RC=$?
[[ $RC -eq 5 ]] || fail "a gh issue list failure should exit 5, got $RC"
[[ -z "$OUT" ]] || fail "a read failure must print nothing on stdout"
ok "a failed open-issue read exits 5 rather than counting chips as stale-free"

printf 'this is not json\n' > "$CLAUDE_ACTIVE_WORK_HANDOFF_DIR/issue-maker-broken-log.json"
OUT=$(run --json 2>"$TMP_DIR/err"); RC=$?
[[ $RC -eq 5 ]] || fail "a malformed chip log should exit 5, got $RC"
grep -q "UNKNOWN" "$TMP_DIR/err" || \
  fail "a malformed chip log must say its contents are unknown, not zero"
ok "a malformed chip log exits 5 and is never read as 'no chips'"
rm -f "$CLAUDE_ACTIVE_WORK_HANDOFF_DIR/issue-maker-broken-log.json"

# --- 16. Missing state is empty, not broken ----------------------------------
rm -f "$HOME/.claude/session-state.json"
rm -f "$CLAUDE_ACTIVE_WORK_HANDOFF_DIR"/issue-maker-*-log.json
set_open_prs 0
set_open_issues ""
JSON=$(run --json) || fail "--json should succeed with no state files at all"
[[ "$(printf '%s' "$JSON" | jq -r '.active')" == "0" ]] || fail "a clean slate should be 0 active"
[[ "$(printf '%s' "$JSON" | jq -r '.free')" == "6" ]] || fail "a clean slate should leave the full cap free"
ok "no session-state and no chip logs is 0 active, not a failure"

# --- 17. --cap makes no network call -----------------------------------------
# Emitters that only need the knob must not pay for (or fail on) the count.
CAP=$(PATH="$TMP_DIR/empty-bin:$PATH" GH_FAKE_PR_FAIL=1 run --cap) || \
  fail "--cap should not depend on the count sources"
[[ "$CAP" == "6" ]] || fail "--cap should still resolve 6, got '$CAP'"
ok "--cap resolves the knob without touching gh or session-state"

# --- 18. Usage errors ---------------------------------------------------------
run --json --free >/dev/null 2>&1; RC=$?
[[ $RC -eq 2 ]] || fail "conflicting output modes should exit 2, got $RC"
run --nope >/dev/null 2>&1; RC=$?
[[ $RC -eq 2 ]] || fail "an unknown flag should exit 2, got $RC"
run --repo 'not a slug' >/dev/null 2>&1; RC=$?
[[ $RC -eq 2 ]] || fail "a malformed --repo should exit 2, got $RC"
run --repo >/dev/null 2>&1; RC=$?
[[ $RC -eq 2 ]] || fail "--repo with no value should exit 2, got $RC"
ok "conflicting modes, unknown flags, and malformed/missing --repo all exit 2"

run --help >/dev/null 2>&1 || fail "--help should exit 0"
ok "--help exits 0"

echo "OK: active-work-cap.sh tests passed"
