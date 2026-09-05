#!/usr/bin/env bash
# merge-sequence.test.sh — Offline unit tests for merge-sequence.sh (issue #756).
# catalog: tests — Tests for `merge-sequence.sh`
# Stubs `gh` and `pr-authorship.sh` so no network / real repo is touched.
# Run from repo root: bash .claude/scripts/tests/merge-sequence.test.sh
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SRC="$REPO_ROOT/.claude/scripts/merge-sequence.sh"

TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

export HOME="$TMP/home"; mkdir -p "$HOME/.claude"
BIN="$TMP/bin"; mkdir -p "$BIN"
SCRIPTS="$TMP/scripts"; mkdir -p "$SCRIPTS"
FIXTURES="$TMP/fixtures"; mkdir -p "$FIXTURES"
export FIXTURES

# merge-sequence.sh resolves pr-authorship.sh next to itself, so run a copy from
# $SCRIPTS alongside the fake.
cp "$SRC" "$SCRIPTS/merge-sequence.sh"; chmod +x "$SCRIPTS/merge-sequence.sh"
SUT="$SCRIPTS/merge-sequence.sh"

# --- Fake pr-authorship.sh ---------------------------------------------------
# Every PR is `mine` unless its number appears in $FAKE_NOT_MINE (space-list) or
# $FAKE_AUTH_UNKNOWN. Mirrors the real exit contract: 0 mine, 1 not_mine,
# 3 not_found, 4 unknown.
cat > "$SCRIPTS/pr-authorship.sh" <<'EOF'
#!/usr/bin/env bash
PR="$1"
case " ${FAKE_NOT_MINE:-} " in *" $PR "*) echo not_mine; exit 1 ;; esac
case " ${FAKE_AUTH_UNKNOWN:-} " in *" $PR "*) echo unknown; exit 4 ;; esac
case " ${FAKE_AUTH_NOTFOUND:-} " in *" $PR "*) exit 3 ;; esac
echo mine; exit 0
EOF
chmod +x "$SCRIPTS/pr-authorship.sh"

# --- Fake gh -----------------------------------------------------------------
# Changed files come from $FIXTURES/files.<PR> (TSV: filename<TAB>changes).
# A PR listed in $FAKE_PR_404 makes the files call fail with a 404.
# Head SHAs come from $FIXTURES/sha.<PR>, defaulting to "sha<PR>".
cat > "$BIN/gh" <<'EOF'
#!/usr/bin/env bash
ARGS="$*"
case "$ARGS" in
  *"repo view"*)
    echo "${FAKE_OWNER_REPO:-solo/repo}"; exit 0 ;;
  *"/files"*)
    PR="$(printf '%s\n' "$ARGS" | sed -n 's|.*/pulls/\([0-9][0-9]*\)/files.*|\1|p')"
    case " ${FAKE_PR_404:-} " in *" $PR "*) echo "gh: Not Found (HTTP 404)" >&2; exit 1 ;; esac
    case " ${FAKE_PR_ERR:-} " in *" $PR "*) echo "gh: server error (HTTP 500)" >&2; exit 1 ;; esac
    [ -f "$FIXTURES/files.$PR" ] || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
    cat "$FIXTURES/files.$PR"; exit 0 ;;
  *"headRefOid"*)
    PR="$(printf '%s\n' "$ARGS" | sed -n 's|.*pr view \([0-9][0-9]*\).*|\1|p')"
    case " ${FAKE_HEADSHA_FAIL:-} " in *" $PR "*) echo "gh: could not resolve PR" >&2; exit 1 ;; esac
    if [ -f "$FIXTURES/sha.$PR" ]; then cat "$FIXTURES/sha.$PR"; else echo "sha$PR"; fi
    exit 0 ;;
esac
echo "unexpected gh call: $ARGS" >&2; exit 1
EOF
chmod +x "$BIN/gh"
export PATH="$BIN:$PATH"

# --- Harness -----------------------------------------------------------------
PASS=0; FAIL=0
ok()   { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$3], got [$2]"; fi; }

# Reset fixtures + env between scenarios.
reset() {
  rm -f "$FIXTURES"/files.* "$FIXTURES"/sha.*
  unset FAKE_NOT_MINE FAKE_AUTH_UNKNOWN FAKE_AUTH_NOTFOUND FAKE_PR_404 FAKE_PR_ERR
}
# files <PR> <file>:<changes> ...
files() {
  local pr="$1"; shift
  : > "$FIXTURES/files.$pr"
  local spec
  for spec in "$@"; do
    printf '%s\t%s\n' "${spec%%:*}" "${spec##*:}" >> "$FIXTURES/files.$pr"
  done
}
act()  { jq -r --arg p "$1" '.plan[$p].action'  <<<"$PLAN"; }
role() { jq -r --arg p "$1" '.plan[$p].role'    <<<"$PLAN"; }

echo "merge-sequence.sh — offline tests"

# =============================================================================
echo "[1] Fixture fleet: 300-line PR in F + two small ready PRs touching F"
# =============================================================================
reset
files 100 ".claude/skills/pm/SKILL.md:300" "docs/a.md:20"
files 101 ".claude/skills/pm/SKILL.md:12"
files 102 ".claude/skills/pm/SKILL.md:5"
PLAN="$("$SUT" --prs 100,101,102)"; RC=$?
check "exit 0 (sequencing applies)"        "$RC"          "0"
check "big PR is the anchor"               "$(jq -r '.groups[0].anchor' <<<"$PLAN")" "100"
check "anchor merges first"                "$(act 100)"   "merge"
check "anchor role"                        "$(role 100)"  "anchor"
check "small PR #101 held"                 "$(act 101)"   "hold"
check "small PR #102 held"                 "$(act 102)"   "hold"
check "footprint counts shared file only"  "$(jq -r '.groups[0].footprints["100"]' <<<"$PLAN")" "300"
check "shared file named in group"         "$(jq -r '.groups[0].shared_files[0]' <<<"$PLAN")" ".claude/skills/pm/SKILL.md"
check "shared file named on held PR"       "$(jq -r '.plan["101"].shared_files[0]' <<<"$PLAN")" ".claude/skills/pm/SKILL.md"
if jq -e '.summary | test("holding #101, #102 until #100 lands") and test("SKILL\\.md")' >/dev/null <<<"$PLAN"; then
  ok "summary names held PRs, anchor, and the shared file"
else
  bad "summary names held PRs, anchor, and the shared file" "got: $(jq -r .summary <<<"$PLAN")"
fi
check "hold state carried out for the anchor" "$(jq -r '.holds["100"].ticks' <<<"$PLAN")" "1"
check "non-shared file excluded from footprint" \
  "$(jq -r '.groups[0].shared_files | length' <<<"$PLAN")" "1"

# =============================================================================
echo "[2] Fleet with no overlap → behaviour unchanged, first-ready merges"
# =============================================================================
reset
files 200 "a.md:10"
files 201 "b.md:10"
files 202 "c.md:10"
PLAN="$("$SUT" --prs 200,201,202)"; RC=$?
check "exit 1 (no sequencing needed)"  "$RC"           "1"
check "#200 merges"                    "$(act 200)"    "merge"
check "#201 merges"                    "$(act 201)"    "merge"
check "#202 merges"                    "$(act 202)"    "merge"
check "all independent"                "$(role 201)"   "independent"
check "no groups"                      "$(jq -r '.groups | length' <<<"$PLAN")" "0"
check "no holds"                       "$(jq -r '.holds | length' <<<"$PLAN")" "0"

# =============================================================================
echo "[3] Hold expiry: anchor goes hard-blocked → held PRs release"
# =============================================================================
reset
files 300 "F.md:300"
files 301 "F.md:10"
files 302 "F.md:8"
PLAN="$("$SUT" --prs 300,301,302 \
  --verdicts '{"300":"BLOCKED:human(@octocat)","301":"wrap","302":"wrap"}')"; RC=$?
check "exit 0 (sequencing applies)"    "$RC"        "0"
check "blocked anchor is not merged"   "$(act 300)" "not_merge_ready"
check "#301 released"                  "$(act 301)" "batch"
check "#302 released"                  "$(act 302)" "batch"
check "anchor_state blocked"           "$(jq -r '.groups[0].anchor_state' <<<"$PLAN")" "blocked"
check "released immediately (tick 1)"  "$(jq -r '.groups[0].ticks' <<<"$PLAN")" "1"

# =============================================================================
echo "[4] Hold expiry: anchor stalls past one cadence tick → release as batch"
# =============================================================================
reset
files 400 "F.md:300"
files 401 "F.md:10"
files 402 "F.md:8"
V='{"400":"fixpr","401":"wrap","402":"wrap"}'
# Tick 1 — anchor is progressing, followers hold.
PLAN="$("$SUT" --prs 400,401,402 --verdicts "$V")"
check "tick 1: #401 held"          "$(act 401)" "hold"
check "tick 1: ticks=1"            "$(jq -r '.groups[0].ticks' <<<"$PLAN")" "1"
HOLDS="$(jq -c .holds <<<"$PLAN")"
# Tick 2 — same head SHA, same verdict: no progress, so release.
PLAN="$("$SUT" --prs 400,401,402 --verdicts "$V" --holds "$HOLDS")"; RC=$?
check "tick 2: exit 0"             "$RC"        "0"
check "tick 2: #401 batched"       "$(act 401)" "batch"
check "tick 2: #402 batched"       "$(act 402)" "batch"
check "tick 2: ticks=2"            "$(jq -r '.groups[0].ticks' <<<"$PLAN")" "2"
check "batch is ONE window"        "$(jq -r '.batches | length' <<<"$PLAN")" "1"
check "batch groups both PRs"      "$(jq -c '.batches[0].prs' <<<"$PLAN")" "[401,402]"
check "batch names the anchor"     "$(jq -r '.batches[0].anchor' <<<"$PLAN")" "400"
if jq -e '.summary | test("releasing #401, #402 as one batch")' >/dev/null <<<"$PLAN"; then
  ok "summary explains the release"
else
  bad "summary explains the release" "got: $(jq -r .summary <<<"$PLAN")"
fi

# =============================================================================
echo "[5] Anchor progress resets the stall counter — the hold continues"
# =============================================================================
reset
files 500 "F.md:300"
files 501 "F.md:10"
echo "sha-old" > "$FIXTURES/sha.500"
V='{"500":"fixpr","501":"wrap"}'
PLAN="$("$SUT" --prs 500,501 --verdicts "$V")"
HOLDS="$(jq -c .holds <<<"$PLAN")"
echo "sha-new" > "$FIXTURES/sha.500"          # anchor pushed a fix → real progress
PLAN="$("$SUT" --prs 500,501 --verdicts "$V" --holds "$HOLDS")"
check "progress resets ticks to 1"  "$(jq -r '.groups[0].ticks' <<<"$PLAN")" "1"
check "follower still held"         "$(act 501)" "hold"

# =============================================================================
echo "[6] Authorship scope: a collaborator's PR never enters hold/batch logic"
# =============================================================================
reset
files 600 "F.md:300"
files 601 "F.md:10"
files 602 "F.md:900"                           # biggest — but not ours
export FAKE_NOT_MINE="602"
PLAN="$("$SUT" --prs 600,601,602)"; RC=$?
unset FAKE_NOT_MINE
check "exit 0"                          "$RC" "0"
check "collaborator PR excluded"        "$(jq -r '.excluded_prs[0].pr' <<<"$PLAN")" "602"
check "exclusion reason"                "$(jq -r '.excluded_prs[0].reason' <<<"$PLAN")" "not_mine"
check "not in prs_considered"           "$(jq -r '[.prs_considered[] | select(. == 602)] | length' <<<"$PLAN")" "0"
check "not in any group"                "$(jq -r '[.groups[].members[] | select(. == 602)] | length' <<<"$PLAN")" "0"
check "no plan entry for it"            "$(jq -r '.plan["602"] // "absent"' <<<"$PLAN")" "absent"
check "anchor is still OUR biggest PR"  "$(jq -r '.groups[0].anchor' <<<"$PLAN")" "600"

echo "[6b] Undetermined authorship fails closed (treated like not_mine)"
reset
files 610 "F.md:300"
files 611 "F.md:10"
export FAKE_AUTH_UNKNOWN="611"
PLAN="$("$SUT" --prs 610,611)"; RC=$?
unset FAKE_AUTH_UNKNOWN
check "unknown author excluded"   "$(jq -r '.excluded_prs[0].reason' <<<"$PLAN")" "unknown"
check "remaining PR has no group" "$(jq -r '.groups | length' <<<"$PLAN")" "0"
check "exit 1 (nothing to sequence)" "$RC" "1"

echo "[6c] --allow-nonauthor includes a foreign PR (explicit user override)"
reset
files 620 "F.md:300"
files 621 "F.md:10"
export FAKE_NOT_MINE="621"
PLAN="$("$SUT" --prs 620,621 --allow-nonauthor)"
unset FAKE_NOT_MINE
check "override includes the PR" "$(act 621)" "hold"
check "nothing excluded"         "$(jq -r '.excluded_prs | length' <<<"$PLAN")" "0"

# =============================================================================
echo "[7] Anchor selection: largest footprint wins; ties break to lowest PR"
# =============================================================================
reset
files 700 "F.md:50"
files 701 "F.md:50"
files 702 "F.md:5"
PLAN="$("$SUT" --prs 702,701,700)"
check "tie breaks to lowest PR number" "$(jq -r '.groups[0].anchor' <<<"$PLAN")" "700"

echo "[7b] Footprint measured in the SHARED file, not overall diff size"
reset
files 710 "F.md:10"  "solo-huge.md:5000"       # huge, but not in the shared file
files 711 "F.md:400"
PLAN="$("$SUT" --prs 710,711)"
check "anchor by shared-file footprint" "$(jq -r '.groups[0].anchor' <<<"$PLAN")" "711"
check "anchor merges"                   "$(act 711)" "merge"
check "other PR holds"                  "$(act 710)" "hold"

# =============================================================================
echo "[8] Transitive grouping: A~B on one file, B~C on another"
# =============================================================================
# #800 and #802 share no file with each other, but both share one with #801, so
# all three are one group. #801's footprint sums across BOTH shared files.
reset
files 800 "X.md:100"
files 801 "X.md:50" "Y.md:60"
files 802 "Y.md:10"
PLAN="$("$SUT" --prs 800,801,802)"
check "one group"                  "$(jq -r '.groups | length' <<<"$PLAN")" "1"
check "all three members"          "$(jq -r '.groups[0].members | length' <<<"$PLAN")" "3"
check "both files counted shared"  "$(jq -r '.groups[0].shared_files | length' <<<"$PLAN")" "2"
check "anchor sums across both"    "$(jq -r '.groups[0].footprints["801"]' <<<"$PLAN")" "110"
check "anchor spans both"          "$(jq -r '.groups[0].anchor' <<<"$PLAN")" "801"
check "#800 held behind it"        "$(act 800)" "hold"
check "#802 held behind it"        "$(act 802)" "hold"

# =============================================================================
echo "[9] Non-wrap verdicts are never held (they were not merging anyway)"
# =============================================================================
reset
files 900 "F.md:300"
files 901 "F.md:10"
files 902 "F.md:8"
PLAN="$("$SUT" --prs 900,901,902 \
  --verdicts '{"900":"wrap","901":"waiting","902":"wrap"}')"
check "anchor merges"                 "$(act 900)" "merge"
check "waiting PR is not_merge_ready" "$(act 901)" "not_merge_ready"
check "ready follower holds"          "$(act 902)" "hold"
check "only the ready one is tracked" "$(jq -c '.holds["900"].members' <<<"$PLAN")" "[902]"

echo "[9b] Independent PR with a non-wrap verdict"
reset
files 910 "A.md:10"
PLAN="$("$SUT" --prs 910 --verdicts '{"910":"rebase"}')"; RC=$?
check "not_merge_ready"  "$(act 910)" "not_merge_ready"
check "exit 1"           "$RC"        "1"

# =============================================================================
echo "[10] --stall-ticks 0 disables holding entirely"
# =============================================================================
reset
files 1000 "F.md:300"
files 1001 "F.md:10"
PLAN="$("$SUT" --prs 1000,1001 --stall-ticks 0)"
check "follower batched, never held" "$(act 1001)" "batch"
check "anchor still merges"          "$(act 1000)" "merge"
if jq -e '.summary | test("holding disabled")' >/dev/null <<<"$PLAN"; then
  ok "release reason says holding is disabled, not 'stalled'"
else
  bad "release reason says holding is disabled, not 'stalled'" "got: $(jq -r .summary <<<"$PLAN")"
fi

# =============================================================================
echo "[10b] Filenames containing spaces still match as a shared file"
# =============================================================================
# Regression guard: a sort|join footprint would split "docs/my notes.md" on
# whitespace and mis-key the join. Membership is matched on the whole field.
reset
files 1010 "docs/my notes.md:300"
files 1011 "docs/my notes.md:10"
PLAN="$("$SUT" --prs 1010,1011)"
check "spaced filename detected as shared" \
  "$(jq -r '.groups[0].shared_files[0]' <<<"$PLAN")" "docs/my notes.md"
check "footprint counted for spaced file" "$(jq -r '.groups[0].footprints["1010"]' <<<"$PLAN")" "300"
check "anchor picked correctly"           "$(jq -r '.groups[0].anchor' <<<"$PLAN")" "1010"
check "follower held"                     "$(act 1011)" "hold"

# =============================================================================
echo "[11] --heads avoids the per-PR head-SHA fetch and feeds the signature"
# =============================================================================
reset
files 1100 "F.md:300"
files 1101 "F.md:10"
PLAN="$("$SUT" --prs 1100,1101 --verdicts '{"1100":"fixpr","1101":"wrap"}' \
  --heads '{"1100":"deadbeef"}')"
check "signature uses the supplied SHA" \
  "$(jq -r '.groups[0].anchor_signature' <<<"$PLAN")" "deadbeef:fixpr"

# =============================================================================
echo "[12] Usage + error handling"
# =============================================================================
reset
"$SUT" >/dev/null 2>&1; check "no --prs → exit 2" "$?" "2"
"$SUT" --prs abc >/dev/null 2>&1; check "non-numeric PR → exit 2" "$?" "2"
"$SUT" --prs 1 --stall-ticks -1 >/dev/null 2>&1; check "negative --stall-ticks → exit 2" "$?" "2"
"$SUT" --prs 1 --verdicts 'not-json' >/dev/null 2>&1; check "bad --verdicts → exit 2" "$?" "2"
"$SUT" --prs 1 --holds '[]' >/dev/null 2>&1; check "array --holds → exit 2" "$?" "2"
"$SUT" --bogus >/dev/null 2>&1; check "unknown flag → exit 2" "$?" "2"
"$SUT" --help >/dev/null 2>&1; check "--help → exit 0" "$?" "0"

files 1200 "F.md:10"
export FAKE_PR_404="1201"
"$SUT" --prs 1200,1201 >/dev/null 2>&1; check "missing PR → exit 3" "$?" "3"
unset FAKE_PR_404
export FAKE_PR_ERR="1201"
files 1201 "F.md:10"
"$SUT" --prs 1200,1201 >/dev/null 2>&1; check "gh failure → exit 4" "$?" "4"
unset FAKE_PR_ERR

# =============================================================================
echo "[12b] --skip-missing: a PR that merged mid-run never sinks the whole plan"
# =============================================================================
# Regression guard: without --skip-missing the planner exits 3 on the first 404,
# so ONE PR merging between fleet discovery and planning would disable overlap
# sequencing for every other PR that tick.
reset
files 1210 "F.md:300"
files 1211 "F.md:10"
export FAKE_PR_404="1212"
PLAN="$("$SUT" --prs 1210,1211,1212 --skip-missing)"; RC=$?
check "exit 0 — surviving PRs still sequenced" "$RC" "0"
check "gone PR excluded"        "$(jq -r '.excluded_prs[] | select(.pr == 1212) | .reason' <<<"$PLAN")" "not_found"
check "survivors still grouped" "$(jq -r '.groups[0].members | length' <<<"$PLAN")" "2"
check "anchor still chosen"     "$(jq -r '.groups[0].anchor' <<<"$PLAN")" "1210"
check "follower still held"     "$(act 1211)" "hold"
# Without the flag the same fleet is a hard error — the strict default is kept
# for explicit single-PR calls, where a typo must not pass silently.
"$SUT" --prs 1210,1211,1212 >/dev/null 2>&1
check "without --skip-missing → exit 3" "$?" "3"
unset FAKE_PR_404

reset
files 1300 "F.md:10"
PLAN="$("$SUT" --prs 1300,1300)"     # duplicate input
check "duplicate PRs deduped" "$(jq -r '.prs_considered | length' <<<"$PLAN")" "1"

# =============================================================================
echo "[12c] Non-canonical PR numbers are usage errors, not mid-run failures"
# =============================================================================
# `001` is not valid JSON, so it would survive a bare ^[0-9]+$ check and then
# break `jq --argjson` deep inside plan generation. `0` is never a real PR.
reset
"$SUT" --prs 001 >/dev/null 2>&1;   check "leading-zero PR → exit 2" "$?" "2"
"$SUT" --prs 0 >/dev/null 2>&1;     check "zero PR → exit 2"         "$?" "2"
"$SUT" --prs 1,007 >/dev/null 2>&1; check "one bad entry rejects all → exit 2" "$?" "2"

# =============================================================================
echo "[12d] --repo must be exactly owner/name"
# =============================================================================
# A component-only check accepts owner/repo/extra and silently queries the
# DIFFERENT real repo `owner/extra`.
reset
files 1310 "F.md:10"
"$SUT" --prs 1310 --repo solo/repo/extra >/dev/null 2>&1; check "3-part repo → exit 2" "$?" "2"
"$SUT" --prs 1310 --repo solo >/dev/null 2>&1;            check "no slash → exit 2"    "$?" "2"
"$SUT" --prs 1310 --repo "solo/re po" >/dev/null 2>&1;    check "space in repo → exit 2" "$?" "2"
"$SUT" --prs 1310 --repo solo/repo >/dev/null 2>&1;       check "valid owner/name → accepted" "$?" "1"

# =============================================================================
echo "[13b] An unresolvable anchor head SHA fails loudly, never fabricates one"
# =============================================================================
# Regression guard for the critical case: substituting a placeholder yields a
# STABLE signature across ticks, so the stall counter advances on an anchor that
# was never observed and releases followers as a batch on invented evidence.
reset
files 1320 "F.md:300"
files 1321 "F.md:10"
export FAKE_HEADSHA_FAIL="1320"
OUT=$("$SUT" --prs 1320,1321 2>&1); RC=$?
unset FAKE_HEADSHA_FAIL
check "unresolvable anchor SHA → exit 4" "$RC" "4"
if grep -q "refusing to" <<<"$OUT"; then ok "error explains the refusal"; else bad "error explains the refusal" "got: $OUT"; fi
if grep -q "unknown:" <<<"$OUT"; then bad "no fabricated sentinel" "emitted an 'unknown:' signature"; else ok "no fabricated sentinel in output"; fi
# --heads supplies the SHA, so the same fleet plans fine without any gh lookup.
export FAKE_HEADSHA_FAIL="1320"
PLAN=$("$SUT" --prs 1320,1321 --heads '{"1320":"abc123"}'); RC=$?
unset FAKE_HEADSHA_FAIL
check "--heads avoids the failing lookup" "$RC" "0"
check "signature uses supplied SHA"       "$(jq -r '.groups[0].anchor_signature' <<<"$PLAN")" "abc123:wrap"

# =============================================================================
echo "[13] Read-only: the planner never writes state or calls a write endpoint"
# =============================================================================
reset
files 1400 "F.md:300"
files 1401 "F.md:10"
BEFORE="$(find "$HOME/.claude" -type f ! -name 'script-usage.log' | LC_ALL=C sort)"
"$SUT" --prs 1400,1401 >/dev/null 2>&1
AFTER="$(find "$HOME/.claude" -type f ! -name 'script-usage.log' | LC_ALL=C sort)"
check "no state files created/removed" "$AFTER" "$BEFORE"

# =============================================================================
printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
