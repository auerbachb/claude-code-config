#!/usr/bin/env bash
# /fixpr Step 5c buckets the retired Graphite check by app slug; Step 5d awaits BugBot only when invited (issue #1953).
# catalog: tests — Runs `/fixpr` Step 5c's real check-bucket block and Step 5d's real BugBot-invited block on fixtures — a check another app names after Graphite stays CI while graphite-app's check is review and never awaited; BugBot silence is awaited only after a `@cursor review` posted since the push or under an unused owner grant, and an unreadable comment list fails closed
#
# WHAT IS UNDER TEST
#   The fenced bash under `<!-- test-anchor: fixpr-step-5c-check-buckets -->`
#   and `<!-- test-anchor: fixpr-step-5d-bugbot-invited -->` in
#   `.claude/skills/fixpr/SKILL.md`, extracted at run time by lib/skill-bash.sh.
#   5c runs on a VERIFY bundle file; 5d runs with `gh` and paid-review-grant.sh
#   stubbed (no network).
#
# WHY (issue #1953, deferred from PR #1951)
#   5c matched Graphite by a name containing "graphite", so another app's pending
#   "Graphite integration" check left both CI and review-pending counts and
#   /fixpr could report clean while it ran. 5d read Step 3b's wording: a BugBot
#   `deferring …` (CI pending) counted as awaited although BugBot is paid and no
#   one would invite it, so /fixpr reported REVIEW_PENDING forever.
#
# Requires: bash 3.2+, jq, Python 3.9+. Offline; no paid triggers/grant consumption.
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
FIXPR="$REPO_ROOT/.claude/skills/fixpr/SKILL.md"
# shellcheck source=lib/skill-bash.sh
source "$TEST_DIR/lib/skill-bash.sh"

TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

PASS=0
FAIL=0
check_eq() {
  if [[ "$3" == "$2" ]]; then
    PASS=$((PASS + 1)); echo "ok   — $1"
  else
    FAIL=$((FAIL + 1)); echo "FAIL — $1 (expected '$2', got '$3')"
  fi
}

BLOCK_5C="$(extract_skill_bash "$FIXPR" fixpr-step-5c-check-buckets)" || exit 1
BLOCK_5D="$(extract_skill_bash "$FIXPR" fixpr-step-5d-bugbot-invited)" || exit 1

############################################################################
echo "== Step 5c: Graphite by publishing-app slug =="
# run_5c <check_runs.all JSON> — prints "IN_PROGRESS FAILING REVIEW_IN_PROGRESS"
run_5c() {
  printf '%s\n' "{\"check_runs\":{\"all\":$1}}" >"$TMP/verify.json"
  VERIFY="$TMP/verify.json" bash -c "$BLOCK_5C"'
echo "COUNTS $IN_PROGRESS $FAILING $REVIEW_IN_PROGRESS"' 2>/dev/null | sed -n 's/^COUNTS //p'
}
check_eq "premise: the 5c block runs and prints its counts on an empty run list" "0 0 0" "$(run_5c '[]')"
check_eq "other app's pending 'Graphite integration' check is CI pending" "1 0 0" \
  "$(run_5c '[{"name":"Graphite integration","status":"in_progress","conclusion":null,"app":{"slug":"github-actions"}}]')"
check_eq "graphite-app's pending check is review, never awaited" "0 0 0" \
  "$(run_5c '[{"name":"r","status":"queued","conclusion":null,"app":{"slug":"graphite-app"}}]')"
check_eq "graphite-app's failed check is not CI failing" "0 0 0" \
  "$(run_5c '[{"name":"Graphite / mergeability_check","status":"completed","conclusion":"failure","app":{"slug":"graphite-app"}}]')"
check_eq "a live reviewer's pending check is still review-pending" "0 0 1" \
  "$(run_5c '[{"name":"Cursor Bugbot","status":"in_progress","conclusion":null,"app":{"slug":"cursor"}}]')"
check_eq "a GitHub Actions job named after a reviewer is CI pending" "1 0 0" \
  "$(run_5c '[{"name":"post-cursor-review","status":"in_progress","conclusion":null,"app":{"slug":"github-actions"}}]')"
check_eq "no app slug: the name still identifies a reviewer check" "0 0 1" \
  "$(run_5c '[{"name":"CodeRabbit","status":"in_progress","conclusion":null}]')"

############################################################################
echo
echo "== Step 5d: BugBot awaited only when invited =="
mkdir -p "$TMP/bin" "$TMP/home/.claude" "$TMP/private"
export HOME="$TMP/home" TMPDIR="$TMP/private" GH_CALL_LOG="$TMP/gh-calls.log"
ln -s "$REPO_ROOT/.claude/scripts" "$HOME/.claude/scripts"
cat >"$TMP/bin/gh" <<'STUB'
#!/usr/bin/env python3
import os,json,sys
from pathlib import Path
from urllib.parse import urlsplit,parse_qs
if int(os.environ.get('GH_STUB_RC','0')):sys.exit(int(os.environ['GH_STUB_RC']))
a=sys.argv[1:]
with open(os.environ['GH_CALL_LOG'],'a') as stream:stream.write(json.dumps(a)+'\n')
if len(a)<2 or a[0]!='api':sys.exit(90)
if os.environ.get('GH_HANG'):
 import time;time.sleep(30)
endpoint=a[1]
if endpoint=='graphql':
 query=a[a.index('-f')+1]
 if not query.startswith('query=query{') or 'mutation' in query:sys.exit(90)
 if os.environ.get('GH_GRAPHQL_FILE'):
  print(Path(os.environ['GH_GRAPHQL_FILE']).read_text());sys.exit(0)
 rows=json.loads(Path(os.environ['GH_TIMELINE_FILE']).read_text()) if os.environ.get('GH_TIMELINE_FILE') else []
 nodes=[]
 for row in rows:
  kind={'head_ref_force_pushed':'HeadRefForcePushedEvent','head_ref_deleted':'HeadRefDeletedEvent','head_ref_restored':'HeadRefRestoredEvent'}.get(row.get('event'))
  if kind:
   node={'__typename':kind,'createdAt':row.get('created_at')}
   if kind=='HeadRefForcePushedEvent':node['afterCommit']={'oid':row.get('commit_id')}
   nodes.append(node)
 print(json.dumps({'data':{'repository':{'pullRequest':{'timelineItems':{'nodes':nodes[-3:],'pageInfo':{'hasPreviousPage':len(nodes)>3}}}}}}));sys.exit(0)
path=endpoint.split('?')[0]; parameters=parse_qs(urlsplit(endpoint).query);page=int(parameters.get('page',['1'])[0])
sha=os.environ.get('GH_LIVE_SHA','a'*40)
if '/pulls/' in path:
 if os.environ.get('GH_MOVE_AFTER_FIRST'):
  marker=Path(os.environ['GH_MOVE_AFTER_FIRST']);count=int(marker.read_text())+1 if marker.exists() else 1;marker.write_text(str(count))
  if count>1:sha='b'*40
 print(json.dumps({'head':{'sha':sha,'ref':'feature','repo':{'full_name':'o/r'}},'created_at':'2026-11-01T00:00:00Z'}))
elif path.endswith('/comments'):
 if os.environ.get('GH_LATE_COMMENT'):
  marker=Path(os.environ['GH_LATE_COMMENT']);count=int(marker.read_text())+1 if marker.exists() else 1;marker.write_text(str(count))
  if count>1:
   if os.environ.get('GH_LATE_COMMENT_FAIL'):sys.exit(1)
   print(json.dumps([{'created_at':'2026-11-06T15:02:00Z','body':'@cursor review'}]));sys.exit(0)
 raw=Path(os.environ['GH_STUB_FILE']).read_text(); parts=[];decoder=json.JSONDecoder()
 try:
  while raw.strip():
   value,index=decoder.raw_decode(raw.lstrip());parts.append(value);raw=raw.lstrip()[index:]
  if 'since' in parameters:
   cutoff=parameters['since'][0]
   flat=[row for part in parts for row in part] if all(isinstance(part,list) for part in parts) else None
   if flat is not None:
    flat=[row for row in flat if not isinstance(row,dict) or not isinstance(row.get('created_at'),str) or row.get('updated_at',row['created_at'])>cutoff]
    print(json.dumps(flat[(page-1)*100:page*100]));sys.exit(0)
  print(json.dumps(parts[page-1] if page<=len(parts) else []))
 except ValueError: print('invalid JSON')
elif path.endswith('/events'):
 print(Path(os.environ['GH_EVENT_FILE']).read_text() if os.environ.get('GH_EVENT_FILE') else json.dumps([{'type':'PushEvent','created_at':'2026-11-06T15:00:00Z','payload':{'head':sha,'ref':'refs/heads/feature'}}]))
elif path.endswith('/timeline'):
 print(Path(os.environ['GH_TIMELINE_FILE']).read_text() if os.environ.get('GH_TIMELINE_FILE') else '[]')
else:sys.exit(90)
STUB
cat >"$TMP/grant" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"$GRANT_LOG"
if [[ -n "${GRANT_STATUS:-}" ]]; then printf 'STATUS=%s\n' "$GRANT_STATUS"
elif [[ "${GRANT_RC:-1}" == 0 ]]; then echo STATUS=available
elif [[ "${GRANT_RC:-1}" == 1 ]]; then echo STATUS=no_grant
else echo STATUS=grant_unreadable; fi
exit "${GRANT_RC:-1}"
STUB
chmod +x "$TMP/bin/gh" "$TMP/grant"

PUSHED='2026-11-06T15:00:00Z'
# run_5d <comments JSON> [gh rc] [grant rc] [grant script path] — prints the verdict
run_5d() {
  printf '%s' "$1" >"$TMP/comments.json"
  : >"$TMP/grant.log"
  PATH="$TMP/bin:$PATH" GH_STUB_FILE="$TMP/comments.json" GH_STUB_RC="${2:-0}" GRANT_RC="${3:-1}" \
    GRANT_LOG="$TMP/grant.log" PAID_GRANT_SH="${4-$TMP/grant}" \
    OWNER=o REPO=r PR_NUMBER=7 DID_PUSH=1 PUSHED_AT="$PUSHED" PUSHED_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa HEAD_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
    bash -u -c "$BLOCK_5D" 2>/dev/null | sed -n 's/^BUGBOT_AWAITED=//p'
}
c() { jq -nc --arg at "$1" --arg b "$2" '{created_at: $at, body: $b}'; }

check_eq "trigger posted after the push: awaited" 1 \
  "$(run_5d "[$(c 2026-11-06T15:02:00Z '@cursor review')]")"
check_eq "no trigger, no grant (Step 3b deferred/skipped): not awaited" 0 \
  "$(run_5d "[$(c 2026-11-06T15:02:00Z 'LGTM')]")"
check_eq "  ...and the grant was asked about the pushed HEAD" "--check 7 --vendor cursor --head aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa --repo o/r" \
  "$(cat "$TMP/grant.log")"
check_eq "trigger posted before the push only: not awaited" 0 \
  "$(run_5d "[$(c 2026-11-06T14:00:00Z '@cursor review')]")"
check_eq "trigger mentioned mid-sentence is not a trigger" 0 \
  "$(run_5d "[$(c 2026-11-06T15:02:00Z 'do not post @cursor review here')]")"
export GH_LATE_COMMENT="$TMP/late-comment-count"
check_eq "invitation posted during grant read cannot publish known not-invited" 1 "$(run_5d '[]')"
rm -f "$GH_LATE_COMMENT"
check_eq "new invitation during boundary read invalidates the old negative" 1 "$(run_5d "[$(c 2026-11-06T14:00:00Z '@cursor review')]")"
rm -f "$GH_LATE_COMMENT"
export GH_LATE_COMMENT_FAIL=1
check_eq "failed final comment reconciliation remains unknown/awaited" 1 "$(run_5d '[]')"
unset GH_LATE_COMMENT GH_LATE_COMMENT_FAIL
check_eq "no trigger but an unused owner grant for this HEAD: awaited" 1 \
  "$(run_5d "[$(c 2026-11-06T15:02:00Z 'LGTM')]" 0 0)"
check_eq "no trigger and grant state unreadable (exit 3): fails closed, awaited" 1 \
  "$(run_5d "[$(c 2026-11-06T15:02:00Z 'LGTM')]" 0 3)"
check_eq "paginated pages are all read" 1 \
  "$(run_5d "$(jq -nc --argjson c "$(c 2026-11-06T14:00:00Z x)" '[range(100) | $c]')[$(c 2026-11-06T15:05:00Z '@cursor review')]")"
check_eq "gh failure fails closed: awaited" 1 "$(run_5d '[]' 1)"
check_eq "unparseable comment list fails closed: awaited" 1 "$(run_5d 'not json' 0)"
check_eq "grant helper missing: unknown is awaited, reported degraded" 1 \
  "$(run_5d "[$(c 2026-11-06T15:02:00Z 'LGTM')]" 0 0 '')"
degraded=$(printf '[]' >"$TMP/comments.json"; PATH="$TMP/bin:$PATH" GH_STUB_FILE="$TMP/comments.json" PAID_GRANT_SH='' \
  OWNER=o REPO=r PR_NUMBER=7 DID_PUSH=1 HEAD_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa PUSHED_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa PUSHED_AT="$PUSHED" bash -u -c "$BLOCK_5D" 2>/dev/null | grep -c '^DEGRADED: BugBot invitation unknown (grant_reader_unavailable)')
check_eq "  ...with the DEGRADED line" 1 "$degraded"

echo
echo "== No-push, SHA-bound history and fail-closed evidence =="
# Strict execution of the actual block. Preserve stdout for reason/path assertions.
run_nopush() {
  printf '%s' "$1" >"$TMP/comments.json"
  : >"$TMP/grant.log"
  NOPUSH_OUT=$(PATH="$TMP/bin:$PATH" GH_STUB_FILE="$TMP/comments.json" GRANT_RC="${2:-1}" \
    GRANT_LOG="$TMP/grant.log" PAID_GRANT_SH="$TMP/grant" \
    OWNER=o REPO=r PR_NUMBER=7 DID_PUSH=0 HEAD_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
    RUN_STARTED_AT=2026-11-07T15:00:00Z \
    env -u PUSHED_AT -u PUSHED_SHA bash -u -c "$BLOCK_5D")
  NOPUSH_RC=$?
}
verdict() { sed -n 's/^BUGBOT_AWAITED=//p' <<<"$NOPUSH_OUT"; }
old="[$(c 2026-11-06T14:00:00Z '@cursor review')]"
current="[$(c 2026-11-06T15:02:00Z '@cursor review synthetic-fixture-marker')]"
run_nopush "$old"
check_eq "strict no-push with unset cutoff reaches a verdict" 0 "$NOPUSH_RC"
check_eq "old-head invitation does not await the never-invited current head" 0 "$(verdict)"
# Empty/stale inherited push variables must be ignored by the no-push branch.
for stale in '' 2026-11-01T00:00:00Z; do
  printf '%s' "$old" >"$TMP/comments.json"
  result=$(PATH="$TMP/bin:$PATH" GH_STUB_FILE="$TMP/comments.json" GRANT_RC=1 GRANT_LOG="$TMP/grant.log" \
    PAID_GRANT_SH="$TMP/grant" OWNER=o REPO=r PR_NUMBER=7 DID_PUSH=0 \
    HEAD_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa PUSHED_SHA=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
    PUSHED_AT="$stale" bash -u -c "$BLOCK_5D" | sed -n 's/^BUGBOT_AWAITED=//p')
  check_eq "no-push ignores empty/stale inherited cutoff '$stale'" 0 "$result"
done
run_nopush "$current"
check_eq "current invitation before rerun start is retained" 1 "$(verdict)"
run_nopush "$old" 0
check_eq "old invitation does not lose an unused current-head owner grant" 1 "$(verdict)"
check_eq "grant reader uses check only and the live exact HEAD" "--check 7 --vendor cursor --head aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa --repo o/r" "$(cat "$TMP/grant.log")"
run_nopush '[]' 3
check_eq "no-push unreadable grant state remains awaited" 1 "$(verdict)"

printf '%s' '[{"event":"head_ref_force_pushed","created_at":"2026-11-06T16:00:00Z","commit_id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}]' >"$TMP/timeline.json"
export GH_TIMELINE_FILE="$TMP/timeline.json"
run_nopush "[$(c 2026-11-06T15:30:00Z '@cursor review')]"
check_eq "a revisited SHA uses its new force-push boundary" 0 "$(verdict)"
run_nopush "[$(c 2026-11-06T16:30:00Z '@cursor review')]"
check_eq "an invitation after the SHA revisit is awaited" 1 "$(verdict)"
printf '%s' '[{"event":"head_ref_force_pushed","created_at":"2026-11-06T16:00:00Z","commit_id":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}]' >"$TMP/timeline.json"
run_nopush "$old"
check_eq "a newer unbound head movement fails closed" 1 "$(verdict)"
check_eq "unbound movement is diagnosed as unknown, not an invitation" 1 "$(grep -c 'head_push_boundary_mismatch' <<<"$NOPUSH_OUT")"
unset GH_TIMELINE_FILE
# Unrelated old timeline/comment history must not exhaust current-head reads.
jq -nc '[range(700) | {event:"commented",created_at:"2026-11-01T12:00:00Z"}] + [{event:"head_ref_force_pushed",created_at:"2026-11-06T15:00:00Z",commit_id:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}]' >"$TMP/busy-timeline.json"
export GH_TIMELINE_FILE="$TMP/busy-timeline.json"
busy_old=$(jq -nc '[range(700) | {body:"old history",created_at:"2026-11-01T12:00:00Z"}]')
run_nopush "$busy_old$current"
check_eq "filtered latest head movement survives 700 unrelated timeline events" 1 "$(verdict)"
run_nopush "$busy_old"
check_eq "700 comments before the current push do not make no-invitation permanently unknown" 0 "$(verdict)"
run_nopush "[$(c 2026-11-06T15:00:00Z '@cursor review')]"
check_eq "invitation exactly at the push second is retained by the since filter" 1 "$(verdict)"
unset GH_TIMELINE_FILE
export GH_GRAPHQL_FILE="$TMP/graphql-response.json"
for bad_history in '{"errors":[{"message":"fixture denied"}],"data":null}' '{"data":{"repository":{"pullRequest":null}}}'; do
  printf '%s' "$bad_history" > "$GH_GRAPHQL_FILE"
  run_nopush "$current"
  check_eq "unavailable filtered history cannot produce a clean invitation verdict" 1 "$(verdict)"
  check_eq "unavailable filtered history is explicitly unknown" 1 "$(grep -c 'DEGRADED: BugBot invitation unknown' <<<"$NOPUSH_OUT")"
done
unset GH_GRAPHQL_FILE
printf '%s' '[]' >"$TMP/events.json"
export GH_EVENT_FILE="$TMP/events.json"
run_nopush "$old"
check_eq "missing server boundary with old invitations is unknown/awaited" 1 "$(verdict)"
check_eq "missing history gets a recoverable unknown reason" 1 "$(grep -c 'head_push_boundary_unavailable' <<<"$NOPUSH_OUT")"
run_nopush '[]'
check_eq "no invitation anywhere plus no grant needs no guessed boundary" 0 "$(verdict)"
unset GH_EVENT_FILE
for malformed in '{}' '[{"body":7,"created_at":"2026-11-06T15:02:00Z"}]' '[{"body":"@cursor review","created_at":"invalid"}]'; do
  run_nopush "$malformed"
  check_eq "malformed comment metadata cannot produce not-invited" 1 "$(verdict)"
done
export GH_MOVE_AFTER_FIRST="$TMP/head-reads"
run_nopush '[]'
check_eq "head movement during reads invalidates a clean verdict" 1 "$(verdict)"
check_eq "head movement is recoverable, not a silent empty result" 1 "$(grep -c 'head_changed' <<<"$NOPUSH_OUT")"
unset GH_MOVE_AFTER_FIRST
# More than the documented page cap is indeterminate, never a partial clean list.
jq -nc '[range(100) | {body:"LGTM",created_at:"2026-11-06T15:02:00Z"}]' >"$TMP/page.json"
full=$(cat "$TMP/page.json")
run_nopush "$full$full$full"
check_eq "three full comment pages fail closed at the bound" 1 "$(verdict)"
check_eq "page bound is reported explicitly" 1 "$(grep -c 'github_page_limit' <<<"$NOPUSH_OUT")"
for status in head_unreadable unexpected_new_status available; do
  export GRANT_STATUS="$status"
  run_nopush '[]' 1
  check_eq "exit 1 with unreadable/unrecognized/inconsistent grant status '$status' is unknown" 1 "$(verdict)"
done
export GRANT_STATUS=consumed
run_nopush '[]' 0
check_eq "success exit without available status cannot produce a clean verdict" 1 "$(verdict)"
export GRANT_STATUS=grant_head_mismatch
run_nopush '[]' 1
check_eq "a known grant for another head is not awaited" 0 "$(verdict)"
unset GRANT_STATUS
# Fail closed when the resolved reader returns malformed or mismatched data.
mkdir -p "$HOME/.claude/skills-worktree/.claude/scripts"
FAKE_READER="$HOME/.claude/skills-worktree/.claude/scripts/bugbot-invitation.sh"
for payload in '{"head_sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","awaited":false,"certainty":"known"}{"head_sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","awaited":false,"certainty":"known"}' 'not-json' '{"head_sha":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","awaited":false,"certainty":"known"}' '{"head_sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","awaited":false,"certainty":"unknown","reason":"fixture","evidence_path":"fixture"}'; do
  printf '%s\n' '#!/usr/bin/env bash' "cat <<'FIXTURE_JSON'" "$payload" 'FIXTURE_JSON' >"$FAKE_READER"
  chmod +x "$FAKE_READER"
  run_nopush '[]'
  check_eq "malformed/mismatched/unknown helper data cannot declare not-invited" 1 "$(verdict)"
done
printf '%s\n' '#!/usr/bin/env bash' "cat <<'FIXTURE_JSON'" '{"head_sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","awaited":false,"certainty":"known"}' 'FIXTURE_JSON' >"$FAKE_READER"
run_nopush '[]'
check_eq "control: matching known false reader result is actually accepted" 0 "$(verdict)"
rm -f "$FAKE_READER"
# A hung API is bounded by the actual reader, not by a successful stubbed verdict.
export GH_HANG=1
started=$SECONDS
run_nopush '[]'
check_eq "hanging API remains awaited" 1 "$(verdict)"
check_eq "timeout records its reason" 1 "$(grep -c 'read_timeout' <<<"$NOPUSH_OUT")"
(( SECONDS - started < 20 ))
check_eq "actual API process-group bound returned before 20 seconds" 0 "$?"
unset GH_HANG
# Private evidence contains timestamps/counts only; never the comment body.
GH_STUB_FILE="$TMP/comments.json";export GH_STUB_FILE
printf '%s' "$current" >"$GH_STUB_FILE"
result=$(PATH="$TMP/bin:$PATH" "$REPO_ROOT/.claude/scripts/bugbot-invitation.sh" --repo o/r --pr 7 --head aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa --grant-helper "$TMP/grant")
EVIDENCE=$(jq -r '.evidence_path' <<<"$result")
check_eq "invitation evidence is retained as valid JSON" true "$(jq -r '.awaited == true and .certainty == "known" and .comment_count == 1' "$EVIDENCE")"
check_eq "evidence excludes raw comment text" 0 "$(grep -c 'synthetic-fixture-marker' "$EVIDENCE" || true)"
python3 - "$EVIDENCE" <<'PRIVATE'
import os,stat,sys
from pathlib import Path
p=Path(sys.argv[1]);assert stat.S_IMODE(p.stat().st_mode)==0o600;assert stat.S_IMODE(p.parent.stat().st_mode)==0o700
PRIVATE
check_eq "evidence file and directory are private" 0 "$?"
# The stub rejects every non-api command; all recorded provider reads are GETs.
python3 - "$GH_CALL_LOG" "$TMP/grant.log" <<'READONLY'
import json,sys
from pathlib import Path
for line in Path(sys.argv[1]).read_text().splitlines():
    args=json.loads(line);assert args[0]=='api'
    if len(args)>1 and args[1]=='graphql':
        assert args[2]=='-f' and len(args)==4 and args[3].startswith('query=query{') and 'mutation' not in args[3]
    else:assert not any(x in args for x in ['-X','--method','-f','-F','--field','--raw-field'])
for line in Path(sys.argv[2]).read_text().splitlines():assert line.startswith('--check ') and '--consume' not in line
READONLY
check_eq "only REST GETs, read-only GraphQL queries and grant checks ran" 0 "$?"

echo
echo "== summary: $PASS passed, $FAIL failed =="
[[ "$FAIL" -eq 0 ]] || exit 1
