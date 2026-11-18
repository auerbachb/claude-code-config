#!/usr/bin/env bash
# pr-snapshot.test.sh — Offline tests for lib/pr-snapshot.sh and its consumers
# (issue #2444, slice 4 of #2421): merge-gate.sh, pr-state.sh (and so
# escalate-review.sh), check-runs-snapshot.sh (and so ci-status.sh) and
# reviewer-of.sh share one short-lived per-PR snapshot of the reviews, inline
# comments, conversation comments, statuses, check-runs and HEAD commit.
# catalog: tests — Per-PR snapshot shared across a poll cycle: each key, each invalidation, partial/failed/corrupt fallbacks, forced-live switches, verdict identical with and without it
#
# The gate decides whether unreviewed code merges, so every scenario asserts both
# halves: the reuse (zero live reads on a hit) and the refusal (a live read, and
# the right answer, on every doubt). No test calls GitHub: `gh` is a stub.
# Run from repo root: bash .claude/scripts/tests/pr-snapshot.test.sh
# shellcheck source=tests/lib/merge-gate-test-fixtures.sh
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/merge-gate-test-fixtures.sh"

SCRIPTS_DIR="$REPO_ROOT/.claude/scripts"
export SLOW_READ_CACHE_DIR="$HOME/.claude/slow-read-cache"
unset SLOW_READ_CACHE_TTL PR_SNAPSHOT_TTL GH_HOST
CALLS="$TMP/calls"
export CALLS

HEAD_B="bbbbbbbb00000000000000000000000000000002"

mv "$BIN/gh" "$BIN/gh.base"
cat > "$BIN/gh" <<'EOF'
#!/usr/bin/env bash
ARGS=" $* "
CUR="${FAKE_PR_HEAD:-deadbeefcafedeadbeefcafedeadbeefcafedead}"
case "$ARGS" in
  " api user --jq .login ")
    echo user >> "$CALLS"; echo solouser; exit 0 ;;
  " pr view "*headRefOid*)
    jq -cn --arg h "$CUR" '{number:1, state:"OPEN", headRefOid:$h, headRefName:"b", url:"https://x/1", baseRefName:"main",
      mergeStateStatus:"CLEAN", isDraft:false, mergeable:"MERGEABLE", reviewDecision:"APPROVED",
      author:{login:"solouser", type:"User"}}'; exit 0 ;;
  *" api graphql "*headRefOid*)
    echo headnow >> "$CALLS"
    [[ "${FAKE_HEADNOW_FAIL:-0}" == 1 ]] && { echo "gh: Server Error (HTTP 502)" >&2; exit 1; }
    printf '%s' "${FAKE_NOW_HEAD:-$CUR}"; exit 0 ;;
  *" api graphql "*reviewThreads*)
    echo threads >> "$CALLS"
    if [[ -n "${FAKE_THREADS:-}" ]]; then printf '%s' "$FAKE_THREADS"; exit 0; fi
    printf '%s' '{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false},"nodes":[]}}}}}'; exit 0 ;;
  " api repos/solo/repo/pulls/1 "|" api repos/{owner}/{repo}/pulls/1 ")
    echo pull >> "$CALLS"
    jq -cn --arg h "$CUR" '{number:1, base:{repo:{full_name:"solo/repo"}}, head:{sha:$h}}'; exit 0 ;;
  *" api --paginate repos/solo/repo/pulls/1/reviews"*|*" api --paginate repos/{owner}/{repo}/pulls/1/reviews"*)
    echo reviews >> "$CALLS"
    [[ "${FAKE_REVIEWS_FAIL:-0}" == 1 ]] && { echo "gh: Server Error (HTTP 502)" >&2; exit 1; }
    [[ "${FAKE_REVIEWS_RATELIMIT:-0}" == 1 ]] && { echo "gh: API rate limit exceeded (HTTP 403)" >&2; exit 1; }
    [[ "${FAKE_REVIEWS_NOTHING:-0}" == 1 ]] && exit 0
    [[ "${FAKE_REVIEWS_BADPAGE:-0}" == 1 ]] && { printf '{"message":"oops"}'; exit 0; }
    [[ "${FAKE_REVIEWS_PAGES:-0}" == 1 ]] && { printf '[{"id":1,"user":{"login":"a"}}][{"id":2,"user":{"login":"b"}}]'; exit 0; }
    printf '%s' "${FAKE_REVIEWS:-[]}"; exit 0 ;;
  *" api --paginate repos/solo/repo/pulls/1/comments"*|*" api --paginate repos/{owner}/{repo}/pulls/1/comments"*)
    echo prcomments >> "$CALLS"; printf '%s' "${FAKE_PR_COMMENTS:-[]}"; exit 0 ;;
  *" api --paginate repos/solo/repo/issues/1/comments"*|*" api --paginate repos/{owner}/{repo}/issues/1/comments"*)
    echo issuecomments >> "$CALLS"; printf '%s' "${FAKE_ISSUE_COMMENTS:-[]}"; exit 0 ;;
  *" api --paginate repos/solo/repo/commits/"*"/statuses"*)
    echo statuses >> "$CALLS"; printf '%s' "${FAKE_COMMIT_STATUSES:-[]}"; exit 0 ;;
  *" api --paginate repos/solo/repo/commits/"*"/check-runs"*)
    echo checkruns >> "$CALLS" ;;
  *" api --paginate repos/solo/repo/actions/runs"*)
    echo workflows >> "$CALLS" ;;
  *" api repos/solo/repo/git/commits/"*)
    echo headcommit >> "$CALLS"
    jq -cn --arg h "$CUR" '{sha:$h, committer:{date:"2026-07-21T09:59:00Z"}}'; exit 0 ;;
esac
exec "$(dirname "$0")/gh.base" "$@"
EOF
chmod +x "$BIN/gh"

# Non-gh helpers the scripts shell out to are real; only gh is stubbed.
export PATH="$BIN:$PATH"
export FAKE_CHECK_RUNS='{"check_runs":[]}'

calls() { local n; n="$( [[ -f "$CALLS" ]] && grep -c "^$1\$" "$CALLS" || true )"; echo "${n:-0}"; }
reset_calls() { : > "$CALLS"; }
reset_all() { rm -rf "$SLOW_READ_CACHE_DIR"; reset_calls; }
files() { find "$SLOW_READ_CACHE_DIR" -type f -name "*__pr-$1.*.json" 2>/dev/null | wc -l | tr -d ' '; }
all_files() { find "$SLOW_READ_CACHE_DIR" -type f -name '*__pr-*.json' 2>/dev/null | wc -l | tr -d ' '; }
age_files() { # seconds: rewrite every entry as saved that long ago
  local f
  for f in "$SLOW_READ_CACHE_DIR"/*.json; do
    [[ -f "$f" ]] || continue
    jq -c --argjson a "$1" '.saved_epoch = (.saved_epoch - $a)' "$f" > "$f.n" && mv "$f.n" "$f"
  done
}
LIVE_KINDS="reviews prcomments issuecomments checkruns workflows headcommit"
live_total() { local k t=0; for k in $LIVE_KINDS statuses; do t=$((t + $(calls "$k"))); done; echo "$t"; }

OUT=""
GATE_RC=0
run_gate() { GATE_RC=0; OUT=$("$SUT" 1 --reviewer cr 2>/dev/null) || GATE_RC=$?; }
verdict() { jq -c '{met, missing, human_changes_requested, ci, reviewer}' <<<"$OUT"; }

CR_HUMAN="$(jq -cn --arg h "$HEAD_SHA" '[{id:11, user:{login:"alice", type:"User"}, state:"CHANGES_REQUESTED", commit_id:$h, submitted_at:"2026-07-21T10:00:00Z", body:"no"}]')"
ONE_RUN="$(bundle "$(cr 1 build success 10)")"

echo "== merge-gate.sh: cold then warm"
reset_all; export FAKE_CHECK_RUNS="$ONE_RUN"
run_gate; V_COLD="$(verdict)"; RC_COLD="$GATE_RC"
for k in reviews prcomments issuecomments checkruns workflows headcommit; do
  check_eq 1 "$(calls $k)" "cold: $k read live once"
done
check_eq 1 "$(files reviews)" "cold: reviews entry stored"
check_eq 1 "$(files check-runs)" "cold: non-empty check-run list stored"
check_eq 1 "$(files head-commit)" "cold: HEAD commit stored"
# After-read of HEAD: one GraphQL call per stored entry, never a REST call.
check_eq 5 "$(calls headnow)" "cold: HEAD re-read once per stored entry (reviews, comments x2, head commit, check-runs)"
reset_calls; run_gate
check_eq 0 "$(live_total)" "warm: zero live per-PR reads"
check_eq 0 "$(calls headnow)" "warm: no HEAD re-read either"
check_eq 1 "$(calls user)" "warm: still exactly one login lookup per run (the gate's own; the snapshot adds none)"
check_eq "$V_COLD" "$(verdict)" "warm: whole gate verdict identical to the cold run"
check_eq "$RC_COLD" "$GATE_RC" "warm: gate exit status identical to the cold run"

echo "== file safety"
f="$(find "$SLOW_READ_CACHE_DIR" -type f -name '*__pr-reviews.*.json' | head -1)"
MODE="$(stat -c '%a' "$f" 2>/dev/null)"; [[ "$MODE" =~ ^[0-7]{3,4}$ ]] || MODE="$(stat -f '%Lp' "$f" 2>/dev/null)"
check_eq 600 "$MODE" "entry is mode 600"
case "$f" in "$HOME/.claude/"*) ok "entry lives under ~/.claude (never a worktree)" ;; *) bad "entry outside ~/.claude: $f" ;; esac
if grep -nE 'auth token|GH_TOKEN|GITHUB_TOKEN|GH_ENTERPRISE_TOKEN|hosts\.yml|gh/config' "$SCRIPTS_DIR/lib/pr-snapshot.sh" >/dev/null; then
  bad "pr-snapshot.sh handles credentials"; else ok "pr-snapshot.sh has no token or credential handling"; fi

echo "== invalidation: HEAD change"
reset_calls; FAKE_PR_HEAD="$HEAD_B" run_gate
check_eq 1 "$(calls reviews)" "new HEAD: reviews read live (a snapshot is never used across a HEAD change)"
check_eq 1 "$(calls checkruns)" "new HEAD: check-runs read live"
check_eq 1 "$(calls headcommit)" "new HEAD: HEAD commit read live"
reset_calls; FAKE_PR_HEAD="$HEAD_B" run_gate
check_eq 0 "$(live_total)" "new HEAD, second run: served from the new HEAD's entry"
reset_calls; run_gate
check_eq 1 "$(calls reviews)" "back on the old HEAD: its entry was replaced, so live again"

echo "== invalidation: lifetime and a changed PR"
reset_all; run_gate; V_EMPTY="$(verdict)"
export FAKE_REVIEWS="$CR_HUMAN"
reset_calls; run_gate
check_eq 0 "$(calls reviews)" "inside the lifetime a just-posted review is not yet seen (bounded by the lifetime)"
check_eq "$V_EMPTY" "$(verdict)" "inside the lifetime the verdict is the one the snapshot was taken at"
age_files 50; reset_calls; run_gate
check_eq 0 "$(calls reviews)" "about 50s old: still shared"
age_files 20; reset_calls; run_gate; V_SNAP="$(verdict)"
check_eq 1 "$(calls reviews)" "over 60s old: read live again"
reset_all; PR_SNAPSHOT_TTL=0 run_gate; V_LIVE="$(verdict)"
check_eq "$V_LIVE" "$V_SNAP" "after the lifetime the verdict for the changed PR is identical with and without the snapshot"
check_eq true "$(jq -r '(.human_changes_requested | length) > 0' <<<"$OUT")" "the new human CHANGES_REQUESTED is seen once the entry has expired"
unset FAKE_REVIEWS

echo "== unresolved threads, mergeStateStatus and HEAD are never in the snapshot"
reset_all; run_gate
check_eq 0 "$(find "$SLOW_READ_CACHE_DIR" -type f -name '*threads*' | wc -l | tr -d ' ')" "no thread entry exists"
check_eq 5 "$(all_files)" "only the five lists are stored (statuses are read only when a required check exists)"

echo "== lifetime clamp and switches"
reset_all; run_gate; age_files 61; reset_calls; PR_SNAPSHOT_TTL=999999 run_gate
check_eq 1 "$(calls reviews)" "TTL 999999 is clamped to 60: a 61s entry is not served"
reset_all; run_gate; age_files 30; reset_calls; PR_SNAPSHOT_TTL=10 run_gate
check_eq 1 "$(calls reviews)" "TTL 10: a 30s entry is not served"
reset_all; run_gate; age_files 30; reset_calls; PR_SNAPSHOT_TTL=abc run_gate
check_eq 0 "$(calls reviews)" "non-numeric TTL falls back to 60: a 30s entry is served"
reset_all; PR_SNAPSHOT_TTL=0 run_gate
check_eq 0 "$(all_files)" "TTL 0: nothing stored"
check_eq 0 "$(calls headnow)" "TTL 0: no extra HEAD read"
check_eq 1 "$(calls user)" "TTL 0: only the gate's own login lookup, none for the snapshot"
reset_calls; PR_SNAPSHOT_TTL=0 run_gate
check_eq 1 "$(calls reviews)" "TTL 0: every read is live"
reset_all; SLOW_READ_CACHE_TTL=0 run_gate
check_eq 0 "$(all_files)" "SLOW_READ_CACHE_TTL=0 (admin-merge.sh and clean-behind-check.sh set it) also turns the snapshot off"
check_eq 0 "$(calls headnow)" "SLOW_READ_CACHE_TTL=0: no extra HEAD read"

echo "== failed, partial and odd reads are never stored"
reset_all; FAKE_REVIEWS_FAIL=1 run_gate
check_eq 0 "$(files reviews)" "failed read: nothing stored"
check_eq 4 "$GATE_RC" "failed read: the gate exits 4 (fails closed)"
check_eq false "$(jq -r '.met' <<<"$OUT")" "failed read: the gate reports not met"
reset_all; FAKE_REVIEWS_RATELIMIT=1 run_gate
check_eq 0 "$(files reviews)" "rate-limited read: nothing stored"
reset_all; FAKE_REVIEWS_NOTHING=1 run_gate
check_eq 0 "$(files reviews)" "a read that printed no page at all is not stored as an empty list"
reset_all; FAKE_REVIEWS_BADPAGE=1 run_gate
check_eq 0 "$(files reviews)" "a page that is not an array is not stored"
reset_all; FAKE_NOW_HEAD="$HEAD_B" run_gate
check_eq 0 "$(all_files)" "HEAD moved while the reads ran: nothing stored"
reset_all; FAKE_HEADNOW_FAIL=1 run_gate
check_eq 0 "$(all_files)" "HEAD re-read failed: nothing stored"
reset_all; export FAKE_CHECK_RUNS='{"check_runs":[]}'; run_gate
check_eq 0 "$(files check-runs)" "an empty check-run list is never stored"
check_eq 1 "$(files reviews)" "an empty review list from a complete successful read is stored"
export FAKE_CHECK_RUNS="$ONE_RUN"
reset_all; FAKE_REVIEWS_PAGES=1 run_gate
check_eq '[{"id":1,"user":{"login":"a"}},{"id":2,"user":{"login":"b"}}]' "$(jq -r '.value' "$(find "$SLOW_READ_CACHE_DIR" -name '*__pr-reviews.*.json')")" "pages are folded into one array when stored"
reset_calls; FAKE_REVIEWS_PAGES=1 run_gate
check_eq 0 "$(calls reviews)" "paged reviews: a hit"

echo "== corrupt, partial and foreign entries fall back to live reads"
corrupt_case() { # label, jq filter or raw replacement mode
  local label="$1" mode="$2" f
  reset_all; run_gate; V0="$(verdict)"
  f="$(find "$SLOW_READ_CACHE_DIR" -name '*__pr-reviews.*.json' | head -1)"
  case "$mode" in
    garbage) printf 'not json{' > "$f" ;;
    empty) : > "$f" ;;
    *) jq -c "$mode" "$f" > "$f.n" && mv "$f.n" "$f" ;;
  esac
  reset_calls; run_gate
  check_eq 1 "$(calls reviews)" "$label: live read"
  check_eq "$V0" "$(verdict)" "$label: same verdict"
}
corrupt_case "garbage file" garbage
corrupt_case "empty file" empty
corrupt_case "wrong HEAD key" '.key = "0000000000000000000000000000000000000001"'
corrupt_case "wrong repo" '.owner_repo = "other/repo"'
corrupt_case "wrong host" '.host = "ghe.example.com"'
corrupt_case "wrong viewer" '.viewer = "someone-else"'
corrupt_case "wrong PR" '.ref = "pr2"'
corrupt_case "future save time" '.saved_epoch = (.saved_epoch + 600)'
corrupt_case "schema 2" '.schema = 2'
corrupt_case "payload is not an array" '.value = "{\"id\":1}"'
corrupt_case "payload item without an id" '.value = "[{\"user\":{\"login\":\"x\"}}]"'
corrupt_case "payload is not a string" '.value = []'
reset_all; run_gate; reset_calls; GH_HOST=ghe.example.com run_gate
check_eq 1 "$(calls reviews)" "a different GH_HOST does not share the entry"
if [[ "$(id -u)" == 0 ]]; then
  echo "SKIP: an entry this process cannot overwrite is not used (chmod 400 does not bind root; run as a normal user)"
else
  reset_all; run_gate; chmod 400 "$(find "$SLOW_READ_CACHE_DIR" -name '*__pr-reviews.*.json' | head -1)"; reset_calls; run_gate
  check_eq 1 "$(calls reviews)" "an entry this process cannot overwrite is not used"
fi

echo "== an older read never replaces a newer entry"
. "$SCRIPTS_DIR/lib/pr-snapshot.sh"
reset_all; pr_snap_init solo/repo 1 "$HEAD_SHA"
NOW="$(date +%s)"
pr_snap_put pr-reviews '[{"id":1}]' "$NOW"
pr_snap_put pr-reviews '[{"id":2}]' "$((NOW - 30))"
check_eq '[{"id":1}]' "$(pr_snap_get pr-reviews)" "the older read left the newer entry alone"

echo "== two concurrent writers: the compare and the rename are one step (per-entry lock)"
# Older writer A passes the compare (no entry yet) and is paused before its rename;
# newer writer B starts meanwhile. Without the lock B would write first and A would
# then overwrite it with the older read. With it B waits, then sees A's older entry
# and replaces it: the newer read survives.
reset_all; pr_snap_init solo/repo 1 "$HEAD_SHA"
NOW="$(date +%s)"
slow_cache_test_hook() {
  slow_cache_test_hook() { :; }   # only the first writer pauses
  ( unset CLAUDE_STATE_LOCK_HELD CLAUDE_STATE_LOCK_TOKEN; pr_snap_put pr-reviews '[{"id":2}]' "$NOW" ) &
  HOOK_B_PID=$!
  sleep 0.5
}
pr_snap_put pr-reviews '[{"id":1}]' "$((NOW - 30))"
wait "$HOOK_B_PID" 2>/dev/null
check_eq '[{"id":2}]' "$(pr_snap_get pr-reviews)" "older writer paused between compare and rename: the newer entry survives"
unset -f slow_cache_test_hook

# The mirror image: the newer writer holds the lock; the older one must leave its entry alone.
reset_all; pr_snap_init solo/repo 1 "$HEAD_SHA"
slow_cache_test_hook() {
  slow_cache_test_hook() { :; }
  ( unset CLAUDE_STATE_LOCK_HELD CLAUDE_STATE_LOCK_TOKEN; pr_snap_put pr-reviews '[{"id":1}]' "$((NOW - 30))" ) &
  HOOK_A_PID=$!
  sleep 0.5
}
pr_snap_put pr-reviews '[{"id":2}]' "$NOW"
wait "$HOOK_A_PID" 2>/dev/null
check_eq '[{"id":2}]' "$(pr_snap_get pr-reviews)" "newer writer paused between compare and rename: the older one writes nothing over it"
unset -f slow_cache_test_hook

# Locking is state-lock.sh's (ownership token, dead-owner recovery, guarded commit).
# A lock that cannot be taken: nothing is written (fail closed), nothing is damaged.
reset_all; pr_snap_init solo/repo 1 "$HEAD_SHA"
pr_snap_put pr-reviews '[{"id":1}]' "$((NOW - 30))"
LOCKED_FILE="$(find "$SLOW_READ_CACHE_DIR" -type f -name '*__pr-reviews.*.json' | head -1)"
mkdir "$LOCKED_FILE.lock"   # a fresh lock with no owner record yet is never treated as dead
pr_snap_put pr-reviews '[{"id":2}]' "$NOW"; RC_LOCKED=$?
check_eq 1 "$RC_LOCKED" "a held lock: the write is refused"
check_eq '[{"id":1}]' "$(pr_snap_get pr-reviews)" "a held lock: the existing entry is untouched"
rmdir "$LOCKED_FILE.lock"
# A lock whose owner died (SIGKILL: no cleanup ran) is recovered by the lock library.
dead_owner_lock() { # <entry file>: leave a lock held by a process that no longer exists
  # A separate process, not a subshell: the lock records $$, which a subshell shares with us.
  env -u CLAUDE_STATE_LOCK_HELD -u CLAUDE_STATE_LOCK_TOKEN bash -c \
    '. "$1/state-lock.sh"; state_lock_acquire "$2" 2 2>/dev/null || exit 1; kill -9 $$' _ "$SCRIPTS_DIR" "$1"
  true
}
dead_owner_lock "$LOCKED_FILE"
check_eq 1 "$([[ -d "$LOCKED_FILE.lock" ]] && echo 1 || echo 0)" "dead-owner fixture: the abandoned lock is on disk"
pr_snap_put pr-reviews '[{"id":2}]' "$NOW"
check_eq '[{"id":2}]' "$(pr_snap_get pr-reviews)" "a lock whose owner died is recovered and the newer read is stored"
check_eq 0 "$(find "$SLOW_READ_CACHE_DIR" -name '*.lock' | wc -l | tr -d ' ')" "no lock directory is left behind"
# The same recovery under a GNU-style stat (what Linux CI runs, where `stat -f` is
# filesystem status and only `stat -c %Y` is the mtime): a lock with no owner record
# and an old mtime is aged out by the lock library. A shim stat behaves that way.
GNU_BIN="$TMP/gnu-stat-bin"; mkdir -p "$GNU_BIN"
REAL_STAT="$(command -v stat)"
cat > "$GNU_BIN/stat" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == "-c" ]]; then
  t="\$("$REAL_STAT" -c "\$2" "\$3" 2>/dev/null)" || t="\$("$REAL_STAT" -f %m "\$3" 2>/dev/null)" || exit 1
  printf '%s\n' "\$t"; exit 0
fi
if [[ "\$1" == "-f" ]]; then printf '  File: "%s"\n    ID: 0 Namelen: 255\n' "\$3"; exit 0; fi
exit 1
EOF
chmod +x "$GNU_BIN/stat"
reset_all; pr_snap_init solo/repo 1 "$HEAD_SHA"
pr_snap_put pr-reviews '[{"id":1}]' "$((NOW - 30))"
LOCKED_FILE="$(find "$SLOW_READ_CACHE_DIR" -type f -name '*__pr-reviews.*.json' | head -1)"
mkdir "$LOCKED_FILE.lock"; touch -t 202001010000 "$LOCKED_FILE.lock"
PATH="$GNU_BIN:$PATH" pr_snap_put pr-reviews '[{"id":2}]' "$NOW"
check_eq '[{"id":2}]' "$(pr_snap_get pr-reviews)" "GNU-style stat: an old ownerless lock is aged out and the newer read stored"
# Two writers find the SAME abandoned lock at once: one breaks it, the other must not
# remove the winner's fresh lock, and the older read must never land last. Repeated
# so the interleavings vary.
for round in 1 2 3 4 5; do
  reset_all; pr_snap_init solo/repo 1 "$HEAD_SHA"
  pr_snap_put pr-reviews '[{"id":0}]' "$((NOW - 40))"
  LOCKED_FILE="$(find "$SLOW_READ_CACHE_DIR" -type f -name '*__pr-reviews.*.json' | head -1)"
  dead_owner_lock "$LOCKED_FILE"
  ( unset CLAUDE_STATE_LOCK_HELD CLAUDE_STATE_LOCK_TOKEN; pr_snap_put pr-reviews '[{"id":1}]' "$((NOW - 20))" ) &
  PID_OLD=$!
  ( unset CLAUDE_STATE_LOCK_HELD CLAUDE_STATE_LOCK_TOKEN; pr_snap_put pr-reviews '[{"id":2}]' "$NOW" ) &
  PID_NEW=$!
  wait "$PID_OLD" 2>/dev/null; wait "$PID_NEW" 2>/dev/null
  GOT="$(pr_snap_get pr-reviews)"
  if [[ "$GOT" == '[{"id":2}]' ]]; then ok "racing cleaners, round $round: the newer entry survives"; else bad "racing cleaners, round $round: got $GOT, expected the newer entry"; fi
done

# The lock must not chain the caller's EXIT trap into command substitutions: a
# caller whose trap cleans up temp files would see it fire early in the subshell.
TRAP_OUT="$(bash -c 'trap "echo CALLER_TRAP_FIRED" EXIT; . "$1/lib/pr-snapshot.sh"; pr_snap_init solo/repo 1 "$2"; x="$(pr_snap_put pr-reviews "[{\"id\":7}]" "$3")"; echo "after:$x"' _ "$SCRIPTS_DIR" "$HEAD_SHA" "$NOW")"
check_eq "after:
CALLER_TRAP_FIRED" "$TRAP_OUT" "a caller's EXIT trap fires once, at its own exit, never inside the lock's command substitution"

echo "== check-run list shapes (check_run_workflows.py builds id-less entries itself)"
reset_all; pr_snap_init solo/repo 1 "$HEAD_SHA"
pr_snap_put pr-check-runs '[{"id":1,"name":"build"},{"id":null,"name":"workflow: w (push)","_workflow_inventory":true}]' "$(date +%s)"
check_eq 1 "$(files check-runs)" "a list with a workflow-inventory entry (id null, marked) is stored"
reset_all; pr_snap_init solo/repo 1 "$HEAD_SHA"
pr_snap_put pr-check-runs '[{"id":1,"name":"build"},{"id":null,"name":"x"}]' "$(date +%s)"
check_eq 0 "$(files check-runs)" "an unmarked id-less entry is odd: not stored"
pr_snap_put pr-check-runs '[{"id":1}]' "$(date +%s)"
check_eq 0 "$(files check-runs)" "an entry without a name is odd: not stored"

echo "== statuses"
reset_all; export FAKE_COMMIT_STATUSES='[{"id":5,"context":"ci","state":"success"}]'
pr_snap_init solo/repo 1 "$HEAD_SHA"
out1="$(pr_snap_list statuses repos/solo/repo/commits/$HEAD_SHA/statuses?per_page=100)"
check_eq 1 "$(calls statuses)" "statuses: cold read live"
reset_calls; out2="$(pr_snap_list statuses repos/solo/repo/commits/$HEAD_SHA/statuses?per_page=100)"
check_eq 0 "$(calls statuses)" "statuses: warm read shared"
check_eq "$(jq -c . <<<"$out1")" "$(jq -c . <<<"$out2")" "statuses: same array either way"
reset_all; export FAKE_COMMIT_STATUSES='[{"id":5,"state":"success"}]'
pr_snap_init solo/repo 1 "$HEAD_SHA"; pr_snap_list statuses "repos/solo/repo/commits/$HEAD_SHA/statuses?per_page=100" >/dev/null
check_eq 0 "$(files statuses)" "statuses without a context are not stored"
unset FAKE_COMMIT_STATUSES

echo "== across the scripts of one cycle"
reset_all; export FAKE_CHECK_RUNS="$ONE_RUN"
run_gate
reset_calls
CRS_SHARED="$("$SCRIPTS_DIR/check-runs-snapshot.sh" --repo solo/repo --head "$HEAD_SHA" --pr 1 2>/dev/null)"; RC_CRS=$?
check_eq 0 "$(( $(calls checkruns) + $(calls workflows) ))" "check-runs-snapshot.sh --pr: served from the gate's snapshot"
check_eq 0 "$RC_CRS" "check-runs-snapshot.sh --pr: exits 0 (a zero-call result only counts if the command succeeded)"
reset_calls
CRS_LIVE="$(PR_SNAPSHOT_TTL=0 "$SCRIPTS_DIR/check-runs-snapshot.sh" --repo solo/repo --head "$HEAD_SHA" --pr 1 2>/dev/null)"; RC_CRS_LIVE=$?
check_eq 0 "$RC_CRS_LIVE" "check-runs-snapshot.sh --pr, forced live control: exits 0"
check_eq "$RC_CRS_LIVE" "$RC_CRS" "check-runs-snapshot.sh --pr: exit status identical to the forced-live control"
check_eq 1 "$(calls checkruns)" "check-runs-snapshot.sh --pr, forced live control: reads live"
check_eq "$(jq -S -c . <<<"$CRS_LIVE")" "$(jq -S -c . <<<"$CRS_SHARED")" "check-runs-snapshot.sh --pr: output identical to the forced-live control"
[[ -n "$CRS_LIVE" ]] && ok "check-runs-snapshot.sh control produced output" || bad "check-runs-snapshot.sh control produced no output"
reset_calls
"$SCRIPTS_DIR/check-runs-snapshot.sh" --repo solo/repo --head "$HEAD_SHA" >/dev/null 2>&1
check_eq 1 "$(calls checkruns)" "check-runs-snapshot.sh without --pr: always live"
reset_calls
CIS_SHARED="$("$SCRIPTS_DIR/ci-status.sh" 1 --format summary 2>/dev/null)"; RC_CIS=$?
check_eq 0 "$(( $(calls checkruns) + $(calls workflows) ))" "ci-status.sh <PR>: check-runs shared too"
reset_calls
CIS_LIVE="$(PR_SNAPSHOT_TTL=0 "$SCRIPTS_DIR/ci-status.sh" 1 --format summary 2>/dev/null)"; RC_CIS_LIVE=$?
check_eq "$RC_CIS_LIVE" "$RC_CIS" "ci-status.sh <PR>: exit status identical to the forced-live control"
check_eq 0 "$RC_CIS" "ci-status.sh <PR>: exits 0 on a green PR"
check_eq "$CIS_LIVE" "$CIS_SHARED" "ci-status.sh <PR>: output identical to the forced-live control"
[[ -n "$CIS_LIVE" ]] && ok "ci-status.sh control produced output" || bad "ci-status.sh control produced no output"
reset_calls
"$SCRIPTS_DIR/ci-status.sh" "$HEAD_SHA" >/dev/null 2>&1
check_eq 1 "$(calls checkruns)" "ci-status.sh <SHA>: no PR, so live"
reset_calls
R="$("$SCRIPTS_DIR/reviewer-of.sh" 1 2>/dev/null)"; RC_RO=$?
check_eq 0 "$(( $(calls reviews) + $(calls prcomments) + $(calls issuecomments) ))" "reviewer-of.sh: the three lists shared"
check_eq 1 "$(calls pull)" "reviewer-of.sh: the PR read stays live (it names HEAD)"
check_eq unknown "$R" "reviewer-of.sh: same answer as the forced-live control below"
check_eq 1 "$RC_RO" "reviewer-of.sh: exits 1 like the live control (no reviewer yet = unknown = exit 1, never a usage error)"
reset_calls; R_LIVE="$(PR_SNAPSHOT_TTL=0 "$SCRIPTS_DIR/reviewer-of.sh" 1 2>/dev/null)"; RC_RO_LIVE=$?
check_eq 3 "$(( $(calls reviews) + $(calls prcomments) + $(calls issuecomments) ))" "reviewer-of.sh with PR_SNAPSHOT_TTL=0: all three live"
check_eq "$RC_RO_LIVE" "$RC_RO" "reviewer-of.sh: exit status identical to the forced-live control"
check_eq "$R_LIVE" "$R" "reviewer-of.sh: answer identical to the forced-live control"
reset_all; FAKE_REVIEWS_FAIL=1 "$SCRIPTS_DIR/reviewer-of.sh" 1 >/dev/null 2>&1; RC=$?
check_eq 2 "$RC" "reviewer-of.sh: a failed list read still exits 2"
reset_all; export FAKE_REVIEWS='[{"id":3,"user":{"login":"coderabbitai[bot]"}}]'
check_eq cr "$("$SCRIPTS_DIR/reviewer-of.sh" 1 2>/dev/null)" "reviewer-of.sh cold: sees the bot"
reset_calls
check_eq cr "$("$SCRIPTS_DIR/reviewer-of.sh" 1 2>/dev/null)" "reviewer-of.sh warm: same answer"
check_eq 0 "$(calls reviews)" "reviewer-of.sh warm: no review read"
unset FAKE_REVIEWS

echo "== pr-state.sh (the escalation script's input) shares the gate's snapshot"
reset_all; export FAKE_CHECK_RUNS="$ONE_RUN" FAKE_COMMIT_STATUSES='[{"id":5,"context":"ci","state":"success"}]'
run_gate; reset_calls
PS_LIVE="$(PR_SNAPSHOT_TTL=0 "$SCRIPTS_DIR/pr-state.sh" --pr 1 --stdout 2>"$TMP/ps.err" | jq -S 'del(.run_started_at)' 2>/dev/null)"
check_eq 1 "$(calls reviews)" "pr-state.sh with the snapshot off: reviews live"
reset_all; run_gate; reset_calls
PS_SHARED="$("$SCRIPTS_DIR/pr-state.sh" --pr 1 --stdout 2>"$TMP/ps.err" | jq -S 'del(.run_started_at)' 2>/dev/null)"
check_eq 0 "$(( $(calls reviews) + $(calls prcomments) + $(calls issuecomments) + $(calls checkruns) + $(calls workflows) ))" "pr-state.sh after the gate: reviews, comments and check-runs shared"
check_eq 1 "$(calls statuses)" "pr-state.sh after the gate: statuses read live once (the gate reads them only with a required check)"
[[ -n "$PS_LIVE" ]] || { bad "pr-state.sh produced no bundle"; cat "$TMP/ps.err" >&2; }
check_eq "$PS_LIVE" "$PS_SHARED" "pr-state.sh bundle identical with and without the snapshot"
unset FAKE_COMMIT_STATUSES

echo "== a merge path reads live: a snapshot saying 'passed and approved' never authorises a merge"
# The snapshot is taken while everything is green and approved; then the world
# changes: a check fails, a human requests changes, a bot opens a thread. A gate
# run that is the last check before a merge (merge-gate.sh --live, which /wrap,
# /merge and Phase C pass) must see each of them at once; a polling run may lag
# by at most the 60s lifetime, except for threads, which are always live.
CUR_APPROVED="$(jq -cn --arg h "$HEAD_SHA" '[{id:21, user:{login:"cursor[bot]", type:"Bot"}, state:"APPROVED", commit_id:$h, submitted_at:"2026-07-21T10:01:00Z", body:"No issues found."}]')"
GREEN_RUN="$(bundle "$(cr 1 build success 10)")"
RED_RUN="$(bundle "$(cr 1 build failure 10)")"
THREAD_OPEN='{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false},"nodes":[{"isResolved":false,"comments":{"nodes":[{"databaseId":9,"body":"bug","author":{"login":"coderabbitai[bot]","__typename":"Bot"}}]}}]}}}}}'
run_gate_b() { GATE_RC=0; OUT=$("$SUT" 1 --reviewer bugbot "$@" 2>/dev/null) || GATE_RC=$?; }
green_world() { export FAKE_REVIEWS="$CUR_APPROVED" FAKE_CHECK_RUNS="$GREEN_RUN"; unset FAKE_THREADS; }
reset_all; green_world
run_gate_b
check_eq true "$(jq -r .met <<<"$OUT")" "baseline: the green, approved PR passes the gate"
check_eq 0 "$GATE_RC" "baseline: exit status 0"

# Polling run (no --live): the snapshot is reused inside its lifetime.
export FAKE_THREADS="$THREAD_OPEN"
reset_calls; run_gate_b
check_eq 0 "$(( $(calls reviews) + $(calls checkruns) + $(calls workflows) ))" "polling run: reviews and check-runs come from the snapshot"
check_eq 1 "$(calls threads)" "polling run: review threads are read live"
check_eq false "$(jq -r .met <<<"$OUT")" "polling run: a new bot finding is caught in the same run (threads are live), so the gate is not met"
check_eq true "$(jq -r '.missing | map(test("unresolved review thread")) | any' <<<"$OUT")" "polling run: the finding is named as an unresolved thread"
unset FAKE_THREADS
export FAKE_CHECK_RUNS="$RED_RUN" FAKE_REVIEWS="$CR_HUMAN"
reset_calls; run_gate_b
check_eq 0 "$(( $(calls reviews) + $(calls checkruns) ))" "polling run: a new CHANGES_REQUESTED and a newly failed check are not read again inside the lifetime (the bounded lag named in the PR body)"

# Merge path (--live): the same snapshot is on disk and is ignored.
for scenario in checks review thread; do
  reset_all; green_world; run_gate_b
  case "$scenario" in
    checks) export FAKE_CHECK_RUNS="$RED_RUN" ;;
    review) export FAKE_REVIEWS="$CR_HUMAN" ;;
    thread) export FAKE_THREADS="$THREAD_OPEN" ;;
  esac
  reset_calls; run_gate_b --live
  check_eq false "$(jq -r .met <<<"$OUT")" "--live ($scenario changed since the snapshot): gate not met"
  check_eq 1 "$([[ "$GATE_RC" -ne 0 ]] && echo 1 || echo 0)" "--live ($scenario): non-zero exit, so no merge"
  check_eq 1 "$(calls reviews)" "--live ($scenario): reviews read live"
  check_eq 1 "$(calls checkruns)" "--live ($scenario): check-runs read live"
  check_eq 1 "$(calls headcommit)" "--live ($scenario): HEAD commit read live"
  check_eq 0 "$(calls headnow)" "--live ($scenario): no snapshot HEAD re-read (nothing is stored)"
done
reset_all; green_world; run_gate_b --live
check_eq 0 "$(all_files)" "--live from cold: nothing stored"
check_eq true "$(jq -r .met <<<"$OUT")" "--live from cold: the green, approved PR still passes"
check_eq 1 "$(calls reviews)" "--live: the nested readers also read live (one review read in total)"
reset_all; PR_SNAPSHOT_TTL=60 SLOW_READ_CACHE_TTL=300 run_gate_b --live
check_eq 0 "$(all_files)" "--live beats a caller that sets both lifetimes high"
for f in .claude/skills/wrap/SKILL.md .claude/skills/merge/SKILL.md .claude/agents/phase-c-merger.md .claude/skills/wrap/references/wrap-merge-gate-recovery.md; do
  if grep -qE '(merge-gate\.sh|MERGE_GATE_SH).*--live' "$REPO_ROOT/$f"; then ok "$f: the pre-merge gate call passes --live"; else bad "$f: the pre-merge gate call does not pass --live"; fi
done
unset FAKE_REVIEWS FAKE_THREADS
export FAKE_CHECK_RUNS="$ONE_RUN"

echo
echo "pr-snapshot.test.sh: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
