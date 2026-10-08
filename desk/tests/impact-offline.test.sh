#!/usr/bin/env bash
# desk/tests/impact-offline.test.sh — offline tests for derived impact (issue
# #1760): `human-queue.sh impact`, its rule (desk/bin/lib/impact.jq), the
# policy thresholds, and the desk's use of it. Needs no database: the derive-
# only form (--no-store) never connects, and every usage error exits 4 before
# any connection attempt. GitHub is a stub (HUMAN_QUEUE_GH) serving fixtures;
# the /pm rank cache lives in a scratch PM_RANK_DIR, written by the real
# pm-rank-cache.sh.
#
# Asserts (issue #1760's test plan and acceptance criteria):
#   5.1  a three-issue chain (#10 <- #15 <- #20): the head derives
#        critical-path with no ranking at all (2 transitive dependents); the
#        middle derives medium, the tail low
#   5.2  a leaf (#40) at rank 40 of a fresh ranking derives low; the rule
#        never reads impact_declared (a declared `high` changes nothing)
#   5.3  a ranking a day old or more is reported unknown (rank null) and the
#        dependents alone decide: a leaf ranked 1 in it derives low, the
#        chain head still critical-path
#   4.1  a fresh rank in the top N derives critical-path; rank N+1 does not
#   4.2  dependents come from the shared parser (issue-deps.sh): markers in
#        comments, in any case, count; a closed issue never does
#   4.4  thresholds from desk/policy.json (HUMAN_QUEUE_POLICY): a raised
#        min-dependents demotes the head, a raised top-N promotes rank 4; an
#        invalid value is the defaults; desk-policy.sh prints both keys
#   rule the parked flag lifts low to medium and nothing else; the basis
#        words
#   fail a failed or missing GitHub read exits 1 with one stderr line naming
#        "dependents unknown": never a derivation from zero dependents
#   usage every usage error exits 4 before any connection; the storing forms
#        need the store (exit 7 without it)
#   show desk.jq's facts line prints the derived impact, its basis, and the
#        declared one; declared alone when nothing was derived
#   skill decisions.md's desk-impact-refresh block runs `impact --open` and
#        prints its exit; the order helper reads impact_derived first
#
# Every CLI case runs under `bash` on PATH and, when /bin/bash is 3.x
# (macOS), under /bin/bash too.
set -uo pipefail

TESTS_DIR=$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/testlib.sh
. "$TESTS_DIR/lib/testlib.sh"
# shellcheck source=lib/skill-block.sh
. "$TESTS_DIR/lib/skill-block.sh"

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: impact-offline.test.sh — jq is not installed (the desk needs it)"
  exit 0
fi

TMP=$(mktemp -d "${TMPDIR:-/tmp}/hq-impact-offline-test.XXXXXX")
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

SHELLS="bash"
if [ -x /bin/bash ] && [ "$(/bin/bash -c 'echo "${BASH_VERSINFO[0]}"')" = "3" ]; then
  SHELLS="bash /bin/bash"
fi

RANK_SH="$HQ_T_DESK_DIR/../.claude/scripts/pm-rank-cache.sh"
LIB="$HQ_T_DESK_DIR/bin/lib"
STUB="$TMP/stub"
mkdir -p "$STUB" "$TMP/rank"

# The gh stub: `issue list --repo O/R ...` serves $STUB/issues-O-R.json (with
# an optional .rc exit code and .err text); anything else exits 64.
cat > "$TMP/gh" <<'EOF'
#!/usr/bin/env bash
dir="${IMPACT_STUB_DIR:?}"
printf '%s\n' "$*" >> "$dir/calls.log"
if [ "${1:-} ${2:-} ${3:-}" = "issue list --repo" ]; then
  f="$dir/issues-$(printf '%s' "$4" | tr '/' '-').json"
  [ -f "$f" ] || { echo "HTTP 404: Could not resolve to a Repository" >&2; exit 1; }
  cat "$f"
  if [ -f "${f%.json}.err" ]; then cat "${f%.json}.err" >&2; fi
  if [ -f "${f%.json}.rc" ]; then exit "$(cat "${f%.json}.rc")"; fi
  exit 0
fi
echo "gh stub: unexpected call: gh $*" >&2
exit 64
EOF
chmod +x "$TMP/gh"

# The fixture: a chain #10 <- #15 <- #20 (the markers in a body, a comment,
# and two cases), a leaf #40, #50 that depends on a closed issue (#5, not in
# the open set) and names itself, and #60 whose cross-repo marker and whose
# `unblocks` of a closed issue (#7) never count.
cat > "$STUB/issues-acme-widgets.json" <<'EOF'
[{"number": 10, "body": "The head of the chain.", "comments": []},
 {"number": 15, "body": "## Related Issues\n\n- Depends on #10", "comments": []},
 {"number": 20, "body": "The tail.", "comments": [{"body": "BLOCKED BY #15 for now."}]},
 {"number": 40, "body": "A leaf nobody depends on.", "comments": []},
 {"number": 50, "body": "Depends on #5. Depends on #50.", "comments": []},
 {"number": 60, "body": "Depends on other/repo#40. This unblocks #7.", "comments": []}]
EOF
printf '[]\n' > "$STUB/issues-acme-empty.json"
printf '[]\n' > "$STUB/issues-acme-down.json"
printf '1\n' > "$STUB/issues-acme-down.rc"
printf 'HTTP 502: Bad Gateway\n' > "$STUB/issues-acme-down.err"

POLICY="$TMP/policy.json"
printf '{}\n' > "$POLICY"

# run_cli SHELL ARGS... — the CLI with no database URL; sets OUT, ERR, RC.
run_cli() {
  local sh="$1"
  shift
  RC=0
  env -u HUMAN_QUEUE_DATABASE_URL HUMAN_QUEUE_GH="$TMP/gh" IMPACT_STUB_DIR="$STUB" \
    PM_RANK_DIR="$TMP/rank" HUMAN_QUEUE_POLICY="$POLICY" \
    "$sh" "$HQ_T_CLI" "$@" >"$TMP/out" 2>"$TMP/err" </dev/null || RC=$?
  OUT=$(cat "$TMP/out")
  ERR=$(cat "$TMP/err")
}
jqo() { printf '%s' "$OUT" | jq -r "$1"; }

# derive SHELL ISSUE — `impact acme/widgets ISSUE --no-store --json`.
derive() { run_cli "$1" impact acme/widgets "$2" --no-store --json; }

# rank_write LINES... — a fresh ranking of acme/widgets, through the real script.
rank_write() {
  printf '%s\n' "$@" | PM_RANK_DIR="$TMP/rank" bash "$RANK_SH" write acme/widgets >/dev/null
}
# rank_aged SECONDS LINES... — the same ranking, written SECONDS ago.
rank_aged() {
  local age="$1" at
  shift
  rank_write "$@"
  at=$(jq -n -r --argjson a "$age" '(now | floor) - $a | todate')
  jq -c --arg at "$at" '.generated_at = $at' "$TMP/rank/acme-widgets.json" > "$TMP/rank/aged.json"
  mv "$TMP/rank/aged.json" "$TMP/rank/acme-widgets.json"
}
# forty — 39 other issues, then #40: #40 ranks 40th.
forty() {
  local i lines=""
  for i in $(seq 101 139); do lines="$lines$i Medium"$'\n'; done
  printf '%s40 Low\n' "$lines"
}

for SH in $SHELLS; do
  rm -f "$TMP/rank/acme-widgets.json"

  # ------------------------------------------------------------ 5.1
  derive "$SH" 10
  check "[$SH] 5.1 head: exit 0, nothing on stderr" "$RC:$ERR" "0:"
  check "[$SH] 5.1 head of a three-issue chain derives critical-path" "$(jqo .impact)" "critical-path"
  check "[$SH] 5.1 ... from two transitive dependents, with no ranking" \
    "$(jqo '[.dependents, (.direct | join(",")), (.transitive | join(",")), .rank_status, .rank_reason, .stored] | join(" ")')" \
    "2 15 15,20 unknown missing false"
  check "[$SH] 5.1 ... the basis in words" "$(jqo .basis)" "2 open dependents, backlog rank unknown"
  derive "$SH" 15
  check "[$SH] 5.1 middle derives medium (one dependent)" "$(jqo '[.impact, .dependents] | join(" ")')" "medium 1"
  derive "$SH" 20
  check "[$SH] 5.1 tail derives low" "$(jqo '[.impact, .dependents] | join(" ")')" "low 0"

  # ------------------------------------------------------------ 4.2
  derive "$SH" 5
  check "[$SH] 4.2 a closed issue's open dependents count (#50 depends on closed #5)" \
    "$(jqo '[.dependents, (.direct | join(",")), .impact] | join(" ")')" "1 50 medium"
  derive "$SH" 60
  check "[$SH] 4.2 unblocking a closed issue (#7) counts nothing" "$(jqo .dependents)" "0"
  derive "$SH" 50
  check "[$SH] 4.2 an issue naming itself is no dependent" "$(jqo '[.dependents, .cycle] | join(" ")')" "0 false"
  derive "$SH" 40
  check "[$SH] 4.2 a cross-repo marker (other/repo#40) never counts" "$(jqo .dependents)" "0"

  # ------------------------------------------------------------ 5.2
  forty | PM_RANK_DIR="$TMP/rank" bash "$RANK_SH" write acme/widgets >/dev/null
  derive "$SH" 40
  check "[$SH] 5.2 a leaf at rank 40 of a fresh ranking derives low" \
    "$(jqo '[.impact, .rank_status, .rank, .tier, .dependents] | join(" ")')" "low fresh 40 Low 0"
  check "[$SH] 5.2 ... the basis names the rank" "$(jqo .basis)" "0 open dependents, backlog rank 40"
  derive "$SH" 20
  check "[$SH] a fresh ranking that does not hold an issue: not ranked" \
    "$(jqo '[.rank_status, (.rank | tostring), .basis] | join(" | ")')" \
    "fresh | null | 0 open dependents, not in the backlog ranking"

  # ------------------------------------------------------------ 4.1 top N
  rank_write "40 Critical" "99 High" "98 High" "20 Medium"
  derive "$SH" 40
  check "[$SH] 4.1 a fresh rank 1 derives critical-path, no dependents needed" \
    "$(jqo '[.impact, .rank] | join(" ")')" "critical-path 1"
  derive "$SH" 20
  check "[$SH] 4.1 rank 4 is past the default top 3" "$(jqo '[.impact, .rank] | join(" ")')" "low 4"

  # ------------------------------------------------------------ 5.3
  rank_aged 86400 "40 Critical" "10 Low"
  derive "$SH" 40
  check "[$SH] 5.3 a ranking 24 hours old is unknown: rank null, the dependents decide" \
    "$(jqo '[.impact, .rank_status, .rank_reason, (.rank | tostring)] | join(" ")')" "low unknown stale null"
  derive "$SH" 10
  check "[$SH] 5.3 ... the chain head is still critical-path from its dependents" \
    "$(jqo '[.impact, .rank_status] | join(" ")')" "critical-path unknown"
  rank_aged 86340 "40 Critical"
  derive "$SH" 40
  check "[$SH] 5.3 a minute under 24 hours is still fresh" "$(jqo '[.impact, .rank_status] | join(" ")')" "critical-path fresh"
  rank_aged -600 "40 Critical"
  derive "$SH" 40
  check "[$SH] 5.3 a ranking from the future is unknown" "$(jqo '[.impact, .rank_reason] | join(" ")')" "low future"
  printf 'not json' > "$TMP/rank/acme-widgets.json"
  derive "$SH" 40
  check "[$SH] 5.3 an unreadable ranking is unknown" "$(jqo '[.impact, .rank_reason] | join(" ")')" "low malformed"
  rm -f "$TMP/rank/acme-widgets.json"

  # ------------------------------------------------------------ 4.4 policy
  printf '{"critical_path_min_dependents": 3}\n' > "$POLICY"
  derive "$SH" 10
  check "[$SH] 4.4 critical_path_min_dependents 3: the head (2 dependents) is medium" \
    "$(jqo '[.impact, .thresholds.critical_path_min_dependents, .thresholds.critical_path_rank_top_n] | join(" ")')" "medium 3 3"
  printf '{"critical_path_rank_top_n": 5}\n' > "$POLICY"
  rank_write "99" "98" "97" "20"
  derive "$SH" 20
  check "[$SH] 4.4 critical_path_rank_top_n 5: rank 4 is critical-path" \
    "$(jqo '[.impact, .rank, .thresholds.critical_path_rank_top_n] | join(" ")')" "critical-path 4 5"
  printf '{"critical_path_rank_top_n": 0}\n' > "$POLICY"
  derive "$SH" 20
  check "[$SH] 4.4 an invalid value is the defaults" \
    "$(jqo '[.impact, .thresholds.critical_path_rank_top_n, .thresholds.critical_path_min_dependents] | join(" ")')" "low 3 2"
  printf '{}\n' > "$POLICY"
  rm -f "$TMP/rank/acme-widgets.json"

  # ------------------------------------------------------------ text
  run_cli "$SH" impact acme/widgets '#10' --no-store
  check "[$SH] text: the issue line, then not stored" "$RC:$OUT" \
    "0:acme/widgets#10: critical-path (2 open dependents, backlog rank unknown)
  not stored (--no-store)"
  run_cli "$SH" impact acme/empty 7 --no-store --json
  check "[$SH] a repo with no open issues: low, zero dependents" "$RC:$(jqo '[.impact, .dependents] | join(" ")')" "0:low 0"

  # ------------------------------------------------------------ failures
  run_cli "$SH" impact acme/down 10 --no-store --json
  check "[$SH] fail: a failing GitHub read exits 1" "$RC" "1"
  check "[$SH] fail: one stderr line" "$(hq_t_lines "$ERR")" "1"
  check_contains "[$SH] fail: names dependents unknown and gh's error" "$ERR" "HTTP 502: Bad Gateway — dependents unknown"
  check "[$SH] fail: nothing on stdout" "$OUT" ""
  run_cli "$SH" impact acme/missing 10 --no-store
  check "[$SH] fail: an unknown repo exits 1" "$RC" "1"
  RC=0
  env -u HUMAN_QUEUE_DATABASE_URL HUMAN_QUEUE_GH="$TMP/no-such-gh" PM_RANK_DIR="$TMP/rank" \
    "$SH" "$HQ_T_CLI" impact acme/widgets 10 --no-store >"$TMP/out" 2>"$TMP/err" </dev/null || RC=$?
  check "[$SH] fail: no gh exits 1" "$RC" "1"
  check_contains "[$SH] fail: ... naming it" "$(cat "$TMP/err")" "gh not found"

  # ------------------------------------------------------------ usage
  for args in "impact" "impact acme/widgets" "impact widgets 10" "impact acme/widgets ten" \
    "impact acme/widgets 0" "impact acme/widgets 10 11" "impact acme/widgets 10 --max-age 5" \
    "impact --open --no-store" "impact --open acme/widgets" "impact --open --max-age" \
    "impact --open --max-age -1" "impact --open --max-age 10081" "impact --open --max-age 1x" \
    "impact --open --max-age 5 --max-age 6" "impact acme/widgets 10 --bogus"; do
    # shellcheck disable=SC2086 # deliberate word splitting of the case's arguments
    run_cli "$SH" $args
    check "[$SH] usage: '$args' exits 4" "$RC" "4"
    check "[$SH] usage: '$args' one stderr line" "$(hq_t_lines "$ERR")" "1"
  done
  run_cli "$SH" impact acme/widgets 10
  check "[$SH] storing needs the store: exit 7 without a URL" "$RC" "7"
  run_cli "$SH" impact --open --max-age 0
  check "[$SH] --open needs the store: exit 7 without a URL" "$RC" "7"
  run_cli "$SH" impact --help
  check "[$SH] --help: exit 0, nothing on stderr" "$RC:$ERR" "0:"
  check_contains "[$SH] --help documents the rule" "$OUT" "critical-path  dependents >= critical_path_min_dependents"
  run_cli "$SH" --help
  check_contains "[$SH] human-queue.sh --help lists impact" "$OUT" "  impact "
done

# ---------------------------------------------------------------- the rule
rule() {
  jq -n -c -L "$LIB" --argjson in "$1" 'include "impact"; $in | impact_derive(3; 2) | [.impact, .impact_parked, .basis, .basis_parked]'
}
check "rule: 2 dependents, unknown rank" "$(rule '{"rank_status":"unknown","rank":null,"dependents":2}')" \
  '["critical-path","critical-path","2 open dependents, backlog rank unknown","2 open dependents, backlog rank unknown, agent parked"]'
check "rule: 1 dependent is medium, parked or not" "$(rule '{"rank_status":"unknown","rank":null,"dependents":1}')" \
  '["medium","medium","1 open dependent, backlog rank unknown","1 open dependent, backlog rank unknown, agent parked"]'
check "rule: a leaf is low; parked lifts it to medium" "$(rule '{"rank_status":"fresh","rank":40,"dependents":0}')" \
  '["low","medium","0 open dependents, backlog rank 40","0 open dependents, backlog rank 40, agent parked"]'
check "rule: fresh rank 3 is critical-path" "$(rule '{"rank_status":"fresh","rank":3,"dependents":0}' | jq -r '.[0]')" "critical-path"
check "rule: a stale rank 1 is ignored" "$(rule '{"rank_status":"unknown","rank":1,"dependents":0}' | jq -r '.[0]')" "low"
check "rule: impact_declared is not an input" \
  "$(rule '{"rank_status":"fresh","rank":40,"dependents":0,"impact_declared":"high"}' | jq -r '.[0]')" "low"

# ---------------------------------------------------------------- policy
POL=$(HUMAN_QUEUE_POLICY="$HQ_T_DESK_DIR/policy.json" bash "$HQ_T_DESK_DIR/bin/desk-policy.sh" 2>&1)
check "4.4 desk/policy.json carries both thresholds at their defaults" \
  "$(printf '%s' "$POL" | jq -c '[.critical_path_rank_top_n, .critical_path_min_dependents]')" "[3,2]"
printf '{"set_size": 2}\n' > "$TMP/partial.json"
POL=$(HUMAN_QUEUE_POLICY="$TMP/partial.json" bash "$HQ_T_DESK_DIR/bin/desk-policy.sh" 2>&1)
check "4.4 a policy file without them is the defaults" \
  "$(printf '%s' "$POL" | jq -c '[.critical_path_rank_top_n, .critical_path_min_dependents]')" "[3,2]"
printf '{"critical_path_min_dependents": "two"}\n' > "$TMP/bad.json"
POL=$(HUMAN_QUEUE_POLICY="$TMP/bad.json" bash "$HQ_T_DESK_DIR/bin/desk-policy.sh" 2>&1)
check_contains "4.4 an invalid value is named in the warning" "$POL" \
  "desk-policy: bad.json: critical_path_min_dependents must be a whole number from 1 to 100; using the defaults"
check_contains "4.4 desk-policy.sh --help documents both keys" "$(bash "$HQ_T_DESK_DIR/bin/desk-policy.sh" --help)" \
  "critical_path_min_dependents"

# ---------------------------------------------------------------- the card
facts() { printf '%s' "$1" | jq -r -L "$HQ_T_DESK_DIR/skill" 'include "desk"; [facts_line] | join("")'; }
check "card: the derived impact, its basis, and the declared one" \
  "$(facts '{"impact_derived":"critical-path","impact_basis":"2 open dependents, backlog rank unknown","impact_declared":"low","parked":false}')" \
  "Impact: critical-path (derived: 2 open dependents, backlog rank unknown; declared low)"
check "card: derived with nothing declared" \
  "$(facts '{"impact_derived":"low","impact_basis":"0 open dependents, backlog rank 40","impact_declared":null,"cost":"~2 min"}')" \
  "Impact: low (derived: 0 open dependents, backlog rank 40) · Cost: ~2 min"
check "card: declared alone when nothing was derived" "$(facts '{"impact_declared":"high","parked":true}')" \
  "Impact: high · Parked: the thread waits for this answer"

# ---------------------------------------------------------------- the order SQL
ORDER=$(HQ_BIN_DIR="$HQ_T_DESK_DIR/bin" bash -c '. "$HQ_BIN_DIR/lib/common.sh"; . "$HQ_BIN_DIR/lib/items.sh"; hq_sql_item_order')
check_contains "order: parked first, then the effective impact (derived, else declared)" "$ORDER" \
  "i.parked DESC,
CASE coalesce(to_jsonb(i)->>'impact_derived', i.impact_declared) WHEN 'critical-path' THEN 0 WHEN 'high' THEN 1"
check_contains "order: then age" "$ORDER" "i.created_at, i.id"
check_contains "the sweep orders Decisions by the same expression" "$(cat "$HQ_T_DESK_DIR/bin/cmd/sweep.sh")" \
  'CASE WHEN i.kind = '"'"'decision'"'"' THEN $(hq_sql_impact_rank) END'

# ---------------------------------------------------------------- the skill
BLOCK=$(hq_t_skill_block "$HQ_T_DESK_DIR/skill/decisions.md" desk-impact-refresh 2>&1) || BLOCK=""
check "skill: decisions.md's desk-impact-refresh block extracts" "$([ -n "$BLOCK" ] && echo yes)" "yes"
printf '%s\n' "$BLOCK" > "$TMP/refresh.sh"
cat > "$TMP/hq-stub" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" > "${HQ_STUB_ARGS:?}"
echo "should not be printed"
exit "${HQ_STUB_RC:-0}"
EOF
chmod +x "$TMP/hq-stub"
for SH in $SHELLS; do
  OUT=$(env HQ="$TMP/hq-stub" HQ_STUB_ARGS="$TMP/hq-args" "$SH" "$TMP/refresh.sh" 2>&1)
  check "[$SH] skill: the block runs impact --open and prints only its exit" "$OUT|$(cat "$TMP/hq-args")" "impact=0|impact --open"
  OUT=$(env HQ="$TMP/hq-stub" HQ_STUB_ARGS="$TMP/hq-args" HQ_STUB_RC=7 "$SH" "$TMP/refresh.sh" 2>&1)
  check "[$SH] skill: a failing refresh reports its exit" "$OUT" "impact=7"
done
DEC=$(cat "$HQ_T_DESK_DIR/skill/decisions.md")
FIRST=$(printf '%s\n' "$DEC" | grep -n 'desk-impact-refresh' | head -1 | cut -d: -f1)
READ=$(printf '%s\n' "$DEC" | grep -n '^1\. \*\*Read the items' | head -1 | cut -d: -f1)
check "skill: the refresh comes before the items are read" \
  "$([ -n "$FIRST" ] && [ -n "$READ" ] && [ "$FIRST" -lt "$READ" ] && echo yes)" "yes"
check_contains "skill: a failure never holds a batch" "$DEC" "Never hold a batch for it."

hq_t_finish "impact-offline.test.sh"
