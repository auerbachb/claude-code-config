#!/usr/bin/env bash
# desk/tests/impact.test.sh — live tests for derived impact (issue #1760),
# against the database in HUMAN_QUEUE_DATABASE_URL.
#
# ISOLATION: that database is the live queue both machines share, so nothing
# here touches its default schema. Every run creates a throwaway schema named
# hq_test_<pid>_<random>_impact, points the CLI at it with HUMAN_QUEUE_SCHEMA,
# and drops it on exit; the number of tables in `public` is asserted
# unchanged. GitHub is a stub (HUMAN_QUEUE_GH); the /pm rank cache lives in a
# scratch PM_RANK_DIR.
#
# Skips with a notice (exit 0) when HUMAN_QUEUE_DATABASE_URL is unset. With the
# URL set, an unreachable database FAILS the suite.
#
# Asserts (issue #1760):
#   4.3  `impact OWNER/REPO ISSUE` stores impact_derived, impact_basis, and
#        impact_derived_at on the open Decisions keyed issue-ISSUE, and never
#        changes impact_declared; Reviews, answered Decisions, other repos,
#        and other keys are left alone; the repo matches in any case
#   5.1  the chain head's Decision stores critical-path
#   5.2  a leaf at rank 40 stores low though its asker declared high
#   5.3  with the ranking a day old, the leaf ranked 1 stores low
#   rule a parked Decision on a leaf stores medium, its basis saying so
#   4.3  the tick, `list`, and the end-of-day sweep order by the derived value
#        (parked, then critical-path, high, medium, low, none, then age); a
#        derivation is not a change `tick` reports
#   open `impact --open` derives what is missing or older than --max-age, one
#        GitHub read per repo, skips local/ repos, and a second run with
#        nothing stale reads GitHub not at all
#   fail a failing GitHub read stores nothing (exit 1) and keeps the values
#        already stored; under --open the other repos are still stored
#   show `get` prints the derived impact, its basis, and the declared one
#   014  over a store without it: `impact` exits 1 naming migrate, `list`
#        still orders; 014 applies over it, and its trigger still keeps 010's
#        to-do writes out of tick while a bump still counts
set -uo pipefail

TESTS_DIR=$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/testlib.sh
. "$TESTS_DIR/lib/testlib.sh"

hq_t_require_db "impact.test.sh"

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: impact.test.sh — jq is not installed (the desk needs it)"
  exit 0
fi

HQ_BIN_DIR="$HQ_T_DESK_DIR/bin"
# shellcheck source=../bin/lib/common.sh
. "$HQ_BIN_DIR/lib/common.sh"
# shellcheck source=../bin/lib/db.sh
. "$HQ_BIN_DIR/lib/db.sh"
HUMAN_QUEUE_SCHEMA=public hq_db_connect

S="hq_test_$$_$(printf '%05d' "$RANDOM")_impact"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/hq-impact-test.XXXXXX")
RANK_SH="$HQ_T_DESK_DIR/../.claude/scripts/pm-rank-cache.sh"
STUB="$TMP/stub"
mkdir -p "$STUB" "$TMP/rank"

admin_sql() { hq_psql -At -c "$1"; }
cleanup() {
  admin_sql "DROP SCHEMA IF EXISTS $S CASCADE;" >/dev/null 2>&1 \
    || echo "WARN: could not drop scratch schema $S — drop it by hand" >&2
  rm -rf "$TMP"
  hq__cleanup_tmp
}
trap cleanup EXIT

sql_in() { hq_psql -At -c "SET search_path TO $S; $1" 2>&1; }

cat > "$TMP/gh" <<'EOF'
#!/usr/bin/env bash
dir="${IMPACT_STUB_DIR:?}"
printf '%s\n' "$*" >> "$dir/calls.log"
if [ "${1:-} ${2:-} ${3:-}" = "issue list --repo" ]; then
  f="$dir/issues-$(printf '%s' "$4" | tr '/' '-').json"
  [ -f "$f" ] || { echo "HTTP 404: Could not resolve to a Repository" >&2; exit 1; }
  if [ -f "${f%.json}.rc" ]; then echo "HTTP 502: Bad Gateway" >&2; exit "$(cat "${f%.json}.rc")"; fi
  cat "$f"
  exit 0
fi
echo "gh stub: unexpected call: gh $*" >&2
exit 64
EOF
chmod +x "$TMP/gh"
: > "$STUB/calls.log"

# acme/widgets: the chain #10 <- #15 <- #20, leaves #40 and #41.
cat > "$STUB/issues-acme-widgets.json" <<'EOF'
[{"number": 10, "body": "Head.", "comments": []},
 {"number": 15, "body": "- Depends on #10", "comments": []},
 {"number": 20, "body": "- Depends on #15", "comments": []},
 {"number": 40, "body": "Leaf.", "comments": []},
 {"number": 41, "body": "Leaf.", "comments": []}]
EOF
# acme/gizmos: #3 <- #4 <- #5.
cat > "$STUB/issues-acme-gizmos.json" <<'EOF'
[{"number": 3, "body": "Head.", "comments": []},
 {"number": 4, "body": "Depends on #3", "comments": []},
 {"number": 5, "body": "Depends on #4", "comments": []}]
EOF

# hq ARGS... — the CLI in the scratch schema; sets OUT, ERR, RC.
hq() {
  RC=0
  HUMAN_QUEUE_SCHEMA="$S" HUMAN_QUEUE_GH="$TMP/gh" IMPACT_STUB_DIR="$STUB" PM_RANK_DIR="$TMP/rank" \
    HUMAN_QUEUE_POLICY="$TMP/no-policy.json" bash "$HQ_T_CLI" "$@" >"$TMP/out" 2>"$TMP/err" </dev/null || RC=$?
  OUT=$(cat "$TMP/out")
  ERR=$(cat "$TMP/err")
}
jqo() { printf '%s' "$OUT" | jq -r "$1"; }
field() { sql_in "SELECT coalesce($2::text, 'NULL') FROM items WHERE id = '$1'"; }
gh_calls() { grep -c 'issue list' "$STUB/calls.log"; }

PUBLIC_BEFORE=$(admin_sql "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public'")

hq migrate
check "migrate the scratch schema" "$RC" "0"
check_contains "migrate applies 014" "$OUT" "applied 014_impact_derived.sql"
if [ "$RC" -ne 0 ]; then
  printf '%s\n' "$ERR"
  hq_t_finish "impact.test.sh"
  exit 1
fi
echo "scratch schema: $S"

# add VAR REPO KEY QUESTION [ARGS...] — a Decision, each a moment older than
# the next so "oldest first" has an order to keep.
N_ADDED=0
add() {
  local var="$1" repo="$2" key="$3" question="$4"
  shift 4
  hq add --kind decision --repo "$repo" --key "$key" --question "$question" --option Yes --option No "$@"
  check "add $var" "$RC" "0"
  printf -v "$var" '%s' "$OUT"
  N_ADDED=$((N_ADDED + 1))
  sql_in "UPDATE items SET created_at = created_at - interval '1 minute' * (30 - $N_ADDED) WHERE id = '$OUT'" >/dev/null
}
add D1 auerbachb/widgets branch:feat/x "A branch-keyed question?" --impact high
add D2 acme/widgets issue-40 "Ship the leaf now?" --impact high
add D3 Acme/Widgets issue-10 "Ship the head first?" --impact low
add D4 acme/widgets issue-41 "Waiting on the other leaf?" --parked
add D5 acme/widgets issue-15 "Middle of the chain?"
add D6 acme/widgets pr-77 "A PR-keyed question?" --impact medium
add D7 acme/gizmos issue-3 "Gizmo head?"
add D8 local/scratch issue-1 "A local repo?"
add DA acme/widgets issue-10 "Already answered?" --impact low
hq answer "$DA" A
check "answer DA" "$RC" "0"
hq add --kind review --repo acme/widgets --key issue-10 --question "filed: the head"
R1="$OUT"
check "add R1" "$RC" "0"

# A fresh ranking: 39 others, then #40 (rank 40).
{ for i in $(seq 101 139); do printf '%s Medium\n' "$i"; done; printf '40 Low\n'; } \
  | PM_RANK_DIR="$TMP/rank" bash "$RANK_SH" write acme/widgets >/dev/null

hq tick
check "the first tick reports everything" "$RC" "0"

# ---------------------------------------------------------------- 4.3 / 5.1
hq impact acme/widgets 10 --json
check "5.1 impact on the chain head: exit 0" "$RC:$ERR" "0:"
check "5.1 the head derives critical-path" "$(jqo '[.impact, .dependents, .stored] | join(" ")')" "critical-path 2 true"
check "4.3 stored on the open Decision keyed issue-10 (repo in any case), only" "$(jqo '[.items[].id] | join(",")')" "$D3"
check "4.3 impact_derived and impact_declared side by side" "$(field "$D3" impact_derived) $(field "$D3" impact_declared)" "critical-path low"
check "4.3 the basis" "$(field "$D3" impact_basis)" "2 open dependents, not in the backlog ranking"
check "4.3 impact_derived_at is set" "$(field "$D3" "(impact_derived_at IS NOT NULL)")" "true"
check "4.3 the answered Decision is left alone" "$(field "$DA" impact_derived)" "NULL"
check "4.3 the Review is left alone" "$(field "$R1" impact_derived)" "NULL"
check "4.3 a derivation records no event" "$(sql_in "SELECT count(*) FROM events WHERE item_id = '$D3'")" "1"
hq tick
check "4.3 a derivation is not a change tick reports" "$RC:$OUT" "0:[]"

# ---------------------------------------------------------------- 5.2 and --open
: > "$STUB/calls.log"
hq impact --open --json
check "--open: exit 0" "$RC:$ERR" "0:"
check "--open: one GitHub read per repo (acme/gizmos, acme/widgets)" "$(gh_calls)" "2"
check "--open: derives what is missing, not the head derived a moment ago" \
  "$(jqo '[.reports[] | "\(.repo)#\(.issue)"] | join(" ")')" "acme/gizmos#3 acme/widgets#15 acme/widgets#40 acme/widgets#41"
check "--open: the local repo is skipped" "$(jqo '[.skipped[] | "\(.repo): \(.reason)"] | join(",")')" "local/scratch: no GitHub remote"
check "--open: nothing failed" "$(jqo '.failed | length')" "0"
check "5.2 a leaf at rank 40 stores low though declared high" \
  "$(field "$D2" impact_derived) $(field "$D2" impact_declared) | $(field "$D2" impact_basis)" \
  "low high | 0 open dependents, backlog rank 40"
check "rule: a parked Decision on a leaf stores medium, saying why" \
  "$(field "$D4" impact_derived) | $(field "$D4" impact_basis)" "medium | 0 open dependents, not in the backlog ranking, agent parked"
check "the middle of the chain stores medium" "$(field "$D5" impact_derived)" "medium"
check "the other repo's head stores critical-path" "$(field "$D7" impact_derived)" "critical-path"
check "a PR-keyed Decision has no issue to derive from" "$(field "$D6" impact_derived)" "NULL"
check "nor has a branch-keyed one" "$(field "$D1" impact_derived)" "NULL"
check "a local repo's Decision is not derived" "$(field "$D8" impact_derived)" "NULL"
hq tick
check "--open's writes are not changes tick reports" "$RC:$OUT" "0:[]"
: > "$STUB/calls.log"
hq impact --open --json
check "--open again: nothing stale, GitHub not read" "$RC:$(gh_calls):$(jqo '.reports | length')" "0:0:0"

# ---------------------------------------------------------------- the order
EXPECT="$D4,$D3,$D7,$D1,$D5,$D6,$D2,$D8"
hq list --kind decision --status open --json
check "4.3 list: parked, then critical-path (age), high, medium (age), low, none" "$(jqo '[.[].id] | join(",")')" "$EXPECT"
hq sweep list --json
check "4.3 the sweep lists Decisions in the same order" \
  "$(jqo '[.items[] | select(.kind == "decision") | .id] | join(",")')" "$EXPECT"
sql_in "DELETE FROM state WHERE key = 'tick_watermark'" >/dev/null
hq tick
check "4.3 tick reports in the same order" "$(jqo '[.[] | select(.kind == "decision" and .status == "open") | .id] | join(",")')" "$EXPECT"
hq get "$D3"
check_contains "show: get prints the derived impact, its basis, and the declared one" "$OUT" \
  "Impact: critical-path (derived: 2 open dependents, not in the backlog ranking; declared low)"
hq get "$D1"
check_contains "show: declared alone when nothing was derived" "$OUT" " · Impact: high"
check_absent "show: … with no derived part" "$OUT" "(derived"

# ---------------------------------------------------------------- 5.3
jq -c --arg at "$(jq -n -r '(now | floor) - 86400 | todate')" '.generated_at = $at | .ranking = [{"rank": 1, "number": 40, "tier": "Critical"}]' \
  "$TMP/rank/acme-widgets.json" > "$TMP/rank/x.json" && mv "$TMP/rank/x.json" "$TMP/rank/acme-widgets.json"
hq impact acme/widgets 40 --json
check "5.3 a day-old ranking is unknown and the dependents decide" \
  "$(jqo '[.rank_status, (.rank | tostring), .impact] | join(" ")'):$(field "$D2" impact_derived)" "unknown null low:low"
jq -c --arg at "$(jq -n -r 'now | floor | todate')" '.generated_at = $at' \
  "$TMP/rank/acme-widgets.json" > "$TMP/rank/x.json" && mv "$TMP/rank/x.json" "$TMP/rank/acme-widgets.json"
hq impact acme/widgets 40
check "4.1 the same ranking fresh: rank 1 is critical-path" "$RC:$(field "$D2" impact_derived)" "0:critical-path"
check "text: the issue line, then each Decision" "$OUT" "acme/widgets#40: critical-path (0 open dependents, backlog rank 1)
  $D2 critical-path"

# ---------------------------------------------------------------- failures
printf '1\n' > "$STUB/issues-acme-widgets.rc"
BEFORE=$(field "$D3" impact_derived_at)
hq impact acme/widgets 10
check "fail: a failing GitHub read exits 1, one stderr line" "$RC:$(hq_t_lines "$ERR")" "1:1"
check_contains "fail: … naming it" "$ERR" "dependents unknown; nothing was stored"
check "fail: the stored value is kept" "$(field "$D3" impact_derived) $(field "$D3" impact_derived_at)" "critical-path $BEFORE"
hq impact --open --max-age 0 --json
check "fail: --open exits 1 when a repo cannot be read" "$RC:$(hq_t_lines "$ERR")" "1:1"
check "fail: … names that repo as failed" "$(jqo '[.failed[] | .repo] | join(",")')" "acme/widgets"
check "fail: … and still stores the repos it could read" "$(jqo '[.reports[] | .repo] | unique | join(",")')" "acme/gizmos"
check "fail: … keeping the unread repo's values" "$(field "$D3" impact_derived) $(field "$D5" impact_derived)" "critical-path medium"
rm -f "$STUB/issues-acme-widgets.rc"
hq impact --open --max-age 0
check "--max-age 0 re-derives every open Decision keyed by an issue" "$RC" "0"
check_contains "… text, one block per issue" "$OUT" "acme/widgets#41: low (0 open dependents, not in the backlog ranking)
  $D4 medium (agent parked)"
check_contains "… the local repo is named as skipped" "$OUT" "skipped local/scratch: no GitHub remote"

# ---------------------------------------------------------------- 014 over an older store
OLD=$(sql_in "ALTER TABLE items DROP COLUMN impact_derived, DROP COLUMN impact_basis, DROP COLUMN impact_derived_at;
DELETE FROM schema_migrations WHERE filename = '014_impact_derived.sql';" | grep -v -E '^(DELETE|ALTER|CREATE|INSERT|SET)')
check "setup: the store is pre-014 again (no error)" "$OLD" ""
hq impact acme/widgets 10
check "before 014: impact exits 1 naming migrate" "$RC:$ERR" \
  "1:human-queue: impact: nothing was stored for acme/widgets: the store is not migrated (run human-queue.sh migrate)"
hq impact --open
check "before 014: --open exits 1 naming migrate" "$RC:$ERR" \
  "1:human-queue: impact: nothing was derived: the store is not migrated (run human-queue.sh migrate)"
hq list --kind decision --status open --json
check "before 014: list still orders, by declared impact" "$RC:$(jqo '.[0].id')" "0:$D4"
hq migrate
check "migrate applies 014 over it" "$RC" "0"
check_contains "… names it" "$OUT" "applied 014_impact_derived.sql"
hq impact acme/widgets 10
check "after 014: impact works again" "$RC:$(field "$D3" impact_derived)" "0:critical-path"
hq tick
hq tag "$D3" prd
hq tick
check "after 014: a to-do write is still not a tick change (010's annotations kept)" "$RC:$OUT" "0:[]"
hq bump "$D3"
hq tick
check "after 014: a bump still is" "$(jqo '[.[].id] | join(",")')" "$D3"
hq migrate
check_absent "014 is not applied twice" "$OUT" "applied 014"

PUBLIC_AFTER=$(admin_sql "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public'")
check "the public schema is unchanged" "$PUBLIC_AFTER" "$PUBLIC_BEFORE"

hq_t_finish "impact.test.sh"
