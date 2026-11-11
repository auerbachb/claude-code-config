#!/usr/bin/env bash
# Local PostgreSQL plus the mobile-gh fixture. No GitHub account or network.
set -euo pipefail
TESTS_DIR=$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/testlib.sh
. "$TESTS_DIR/lib/testlib.sh"
hq_t_require_db "mobile-inbox.test.sh"
HQ_BIN_DIR="$HQ_T_DESK_DIR/bin"
# shellcheck source=../bin/lib/common.sh
. "$HQ_BIN_DIR/lib/common.sh"
# shellcheck source=../bin/lib/db.sh
. "$HQ_BIN_DIR/lib/db.sh"
HUMAN_QUEUE_SCHEMA=public hq_db_connect
export HUMAN_QUEUE_SCHEMA="hq_test_$$_${RANDOM}_mobile"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/hq-mobile-test.XXXXXX")
cleanup() {
  hq_psql -At -c "DROP SCHEMA IF EXISTS $HUMAN_QUEUE_SCHEMA CASCADE;" >/dev/null 2>&1 || true
  rm -rf "$tmp"
  hq__cleanup_tmp
}
trap cleanup EXIT
export DESK_MOBILE_CONFIG="$tmp/mobile.json" MOBILE_GH_STATE="$tmp/remote.json"
export DESK_MOBILE_GH_BIN="$TESTS_DIR/fixtures/mobile-gh.py"
sync() { python3 "$HQ_BIN_DIR/mobile-sync.py" --session fixture-control; }
writes() { jq -r '.writes | length' "$MOBILE_GH_STATE"; }
set_remote() { jq "$1" "$MOBILE_GH_STATE" > "$tmp/remote.tmp"; mv "$tmp/remote.tmp" "$MOBILE_GH_STATE"; }
printf '%s\n' '{"private":false,"issues":[],"writes":[]}' > "$MOBILE_GH_STATE"
check "without configuration the mirror is inactive" "$(sync)" '[]'
check "inactive mirror never calls the destination" "$(writes)" 0
(
  umask 077
  printf '%s\n' '{"repo":"owner/mobile","repo_id":101,"operator_id":77,"signing_key":"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"}' > "$DESK_MOBILE_CONFIG"
)
"$HQ_T_CLI" migrate >/dev/null
"$HQ_T_CLI" register-control fixture-control >/dev/null
"$HQ_T_CLI" add --kind decision --repo owner/private-work --key issue-1 --session private-worker \
  --question 'Ready to ship @someone? https://example.invalid/private [settings](/internal/path)' --option Ship --option Wait \
  --default Wait --context 'never export this worker context' >/dev/null
"$HQ_T_CLI" add --kind decision --repo owner/private-work --key issue-2 --session other-worker \
  --question 'Choose a fallback?' --option Local --option Remote >/dev/null
"$HQ_T_CLI" add --kind review --repo owner/private-work --key pr-3 --question 'Review the fixture' >/dev/null
rc=0; sync > "$tmp/out" 2> "$tmp/err" || rc=$?
check "public destination fails closed" "$rc" 1
check "public destination receives no exports" "$(writes)" 0
set_remote '.private=true|.repo_id=102'
rc=0; sync > "$tmp/out" 2> "$tmp/err" || rc=$?
check "wrong private repository identity fails closed" "$rc" 1
check "unmatched destination receives no exports" "$(writes)" 0
set_remote 'del(.repo_id)'
hq_psql -At -c "SET search_path TO $HUMAN_QUEUE_SCHEMA; DROP TABLE mobile_inbox_receipts;
  DELETE FROM schema_migrations WHERE filename='016_mobile_inbox_receipts.sql';" >/dev/null
rc=0; sync > "$tmp/out" 2> "$tmp/err" || rc=$?
check "missing mobile receipt migration fails closed" "$rc" 1
check "an incomplete rollout receives no exports" "$(writes)" 0
"$HQ_T_CLI" migrate >/dev/null
check "initial private projection has no wake pointers" "$(sync)" '[]'
check "a Decision and Review are projected once each" "$(writes)" 3
payload=$(jq -r '.issues[]|.title,.body' "$MOBILE_GH_STATE")
check_contains "options are visible on the projected Decision" "$payload" 'A. Ship'
check_contains "a Review has a one-line title" "$payload" 'R-1 · Review the fixture'
check_absent "worker session is not exported" "$payload" 'private-worker'
check_absent "worker context is not exported" "$payload" 'never export this worker context'
check_absent "private repo identity is not exported" "$payload" 'owner/private-work'
check_absent "projected mentions do not notify other users" "$payload" '@someone'
check_absent "embedded links are omitted" "$payload" 'example.invalid'
check_absent "local paths do not cross the mirror boundary" "$payload" 'internal'
check_contains "the path omission renders as literal text" "$payload" 'path omitted'
sync >/dev/null
check "repeat sync does not create duplicates" "$(writes)" 3

python3 - "$MOBILE_GH_STATE" <<'PY'
import json,sys
from pathlib import Path
p=Path(sys.argv[1]); d=json.loads(p.read_text())
def c(n, text, user=77, edited=False):
    return {"id": n, "user": {"id": user, "type": "User"}, "body": text,
            "created_at": "2026-11-09T20:01:00Z",
            "updated_at": "2026-11-09T20:02:00Z" if edited else "2026-11-09T20:01:00Z"}
issues={x["title"].split()[0]:x for x in d["issues"]}
issues["D-1"]["title"]="D-1 · edited projection"
d["comments"]={str(issues["D-1"]["number"]):[c(1000,"answer: B",66),c(1001,"answer: B",edited=True),c(1002,"answer: A")],
               str(issues["D-2"]["number"]):[c(1003,"answer: B")],
               str(issues["R-1"]["number"]):[c(1004,"reviewed")]}
p.write_text(json.dumps(d))
PY
# A stale projection must fail even when the item timestamp is unchanged.
before=$("$HQ_T_CLI" get D-2 --json | jq -r .updated_at)
hq_psql -At -c "SET search_path TO $HUMAN_QUEUE_SCHEMA;
  ALTER TABLE items DISABLE TRIGGER items_touch_updated_at;
  UPDATE items SET question = 'Choose a newer fallback?' WHERE id = 'D-2';
  ALTER TABLE items ENABLE TRIGGER items_touch_updated_at;" >/dev/null
check "the changed Decision retained the same timestamp" "$("$HQ_T_CLI" get D-2 --json | jq -r .updated_at)" "$before"
check "edited or stale projections do not apply a Decision" "$(sync)" '[]'
check "the Review toggle uses the existing lifecycle" "$("$HQ_T_CLI" get R-1 --json | jq -r .status)" reviewed
check "a stale phone reply cannot overwrite the source item" "$("$HQ_T_CLI" get D-2 --json | jq -r .status)" open
check "an edited mirror cannot supply an answer" "$("$HQ_T_CLI" get D-1 --json | jq -r .status)" open
check "an edited signed issue is replaced with a clean copy" \
  "$(jq -r '[.issues[] | select(.title | startswith("D-1 ")) | .state] | join(",")' "$MOBILE_GH_STATE")" 'closed,open'
set_remote '(.issues[] | select(.title | startswith("D-1 ")) | select(.state == "open")) as $fresh
  | .comments[($fresh.number | tostring)] = [{
      id:1007,user:{id:77,type:"User"},body:"answer: A",
      created_at:"2026-11-09T20:01:00Z",updated_at:"2026-11-09T20:01:00Z"
    }]'
out=$("$HQ_BIN_DIR/desk-tick.sh" --session fixture-control --generation fixture-gen --once)
check_contains "the normal desk tick emits the exact pending wake id" "$out" 'desk-tick fixture-gen mobile D-1'
notice_order=$(printf '%s\n' "$out" | awk '$3=="new" || $3=="mobile" {print $3}')
check "ordinary desk notices are emitted before the optional sync result" "$notice_order" $'new\nmobile'
check "the authorized unedited reply is the stored answer" "$("$HQ_T_CLI" get D-1 --json | jq -r .answer)" Ship
check "the pending wake is durable across another sync" "$(sync)" '["D-1"]'
mv "$DESK_MOBILE_CONFIG" "$tmp/disabled.json"
writes_before=$(writes)
out=$("$HQ_BIN_DIR/desk-tick.sh" --session fixture-control --generation fixture-gen --once)
check_contains "disabling the mirror still delivers a committed wake" "$out" 'desk-tick fixture-gen mobile D-1'
check "disabling the mirror sends nothing to GitHub" "$(writes)" "$writes_before"
mv "$tmp/disabled.json" "$DESK_MOBILE_CONFIG"
"$HQ_T_CLI" wake D-1 --result sent >/dev/null
check "the existing wake receipt removes the mobile pointer" "$(sync)" '[]'

"$HQ_T_CLI" add --kind review --repo owner/private-work --key pr-4 --question 'Read another fixture' >/dev/null
sync >/dev/null
python3 - "$MOBILE_GH_STATE" <<'PYFIX'
import json,sys
from pathlib import Path
p=Path(sys.argv[1]); d=json.loads(p.read_text())
issues={x["title"].split()[0]:x for x in d["issues"] if x["state"]=="open"}
def c(n,text):
    return {"id":n,"user":{"id":77,"type":"User"},"body":text,
            "created_at":"2026-11-09T20:02:00Z","updated_at":"2026-11-09T20:02:00Z"}
d["comments"][str(issues["D-2"]["number"])]=[c(1005,"answer: sk-"+"fixture0123456789test012345")]
d["comments"][str(issues["R-2"]["number"])]=[c(1006,"reviewed")]
p.write_text(json.dumps(d))
PYFIX
check "a refused answer does not halt the mobile pass" "$(sync)" '[]'
check "the credential-shaped reply is not stored" "$("$HQ_T_CLI" get D-2 --json | jq -r .answer)" null
check "an independent valid Review still updates" "$("$HQ_T_CLI" get R-2 --json | jq -r .status)" reviewed
# A blocked GitHub call must not hold up the next desktop notification.
mkdir "$tmp/slow"
MOBILE_GH_BARRIER="$tmp/slow" HUMAN_QUEUE_TICK_SECONDS=1 \
  "$HQ_BIN_DIR/desk-tick.sh" --session fixture-control --generation fixture-slow > "$tmp/slow/out" 2>&1 &
loop=$!
for _ in {1..50}; do
  [ ! -e "$tmp/slow/ready" ] || break
  sleep 0.1
done
check "the remote provider is waiting" "$(test -e "$tmp/slow/ready" && echo yes)" yes
"$HQ_T_CLI" add --kind decision --repo owner/private-work --key issue-5 \
  --question 'A desktop item arrived during sync' >/dev/null
noticed=no
for _ in {1..40}; do
  if grep -F 'desk-tick fixture-slow new D-3' "$tmp/slow/out" >/dev/null; then noticed=yes; break; fi
  sleep 0.1
done
check "desktop notices arrive while the remote pass is blocked" "$noticed" yes
touch "$tmp/slow/release"
kill -TERM "$loop" 2>/dev/null || true
wait "$loop" 2>/dev/null || true

# Hold the same lock registration uses, then replace the desk before the
# waiting mobile transaction can read control_session.
version=$("$HQ_T_CLI" mobile-reply snapshot fixture-control | jq -r '.[] | select(.id == "D-2") | .version')
hq_psql -At -f - >/dev/null <<SQL &
SET search_path TO $HUMAN_QUEUE_SCHEMA;
BEGIN;
SELECT pg_advisory_xact_lock(hashtextextended('human-queue:control:$HUMAN_QUEUE_SCHEMA', 0));
\! touch "$tmp/guard-held"
\! i=0; while [ ! -e "$tmp/guard-release" ] && [ \$i -lt 100 ]; do sleep 0.1; i=\$((i+1)); done
UPDATE state SET value = 'fixture-successor' WHERE key = 'control_session';
COMMIT;
SQL
guard=$!
for _ in {1..100}; do
  [ ! -e "$tmp/guard-held" ] || break
  sleep 0.1
done
check "handover transaction acquired the control lock" "$(test -e "$tmp/guard-held" && echo yes)" yes
printf 'A' | "$HQ_T_CLI" mobile-reply apply fixture-control 101 1010 D-2 "$version" answer > "$tmp/guarded-reply" &
reply=$!
waiting=f
for _ in {1..50}; do
  waiting=$(hq_psql -At -c "SELECT EXISTS (SELECT 1 FROM pg_stat_activity
    WHERE wait_event = 'advisory' AND query LIKE '%human-queue:control:%$HUMAN_QUEUE_SCHEMA%')")
  [ "$waiting" != t ] || break
  sleep 0.1
done
touch "$tmp/guard-release"
wait "$guard"
wait "$reply"
check "mobile apply waited on the registration lock" "$waiting" t
check "the replaced desk cannot apply a waiting phone answer" "$(cat "$tmp/guarded-reply")" stale
check "the replaced desk left the Decision open" "$("$HQ_T_CLI" get D-2 --json | jq -r .status)" open

hq_t_finish "mobile-inbox.test.sh"
