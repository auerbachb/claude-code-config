#!/usr/bin/env bash
# catalog: tests — Tests for `safe-close-stop.sh`: stop plan, park record `/go-on` can resume, ceiling clear, and verification that never trusts a stop's exit status
#
# Builds its own fixtures (fake HOME, throwaway repo, a stub `gh`, dummy
# processes it spawns and reaps itself) so it never touches real session state,
# GitHub, or anyone's processes. Run from the repo root.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SCRIPT="$ROOT/.claude/scripts/safe-close-stop.sh"
REGISTRY="$ROOT/.claude/scripts/background-task-registry.sh"
TMP="$(mktemp -d)"
SPAWNED=""
cleanup() {
  local p
  for p in $SPAWNED; do kill "$p" 2>/dev/null; wait "$p" 2>/dev/null; done
  rm -rf "$TMP"
}
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok   — $*"; }

export HOME="$TMP/home"
mkdir -p "$HOME/.claude" "$TMP/bin"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
REPO=acme/widgets
SESSION=sess-1
STATE="$HOME/.claude/session-state.json"

cat > "$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
  "api user") echo me ;;
  "pr list") sed "s/__HEAD__/$(git rev-parse HEAD)/g" "$STUB_PR_LIST" ;;
  "issue list") echo '[]' ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH"

git init -q --bare "$TMP/origin.git"
git clone -q "$TMP/origin.git" "$TMP/work" 2>/dev/null
W="$TMP/work"
git -C "$W" checkout -q -b main
echo a > "$W/a.txt"; git -C "$W" add a.txt; git -C "$W" commit -q -m base
git -C "$W" push -q -u origin main 2>/dev/null
git -C "$W" checkout -q -b feature-x
echo b > "$W/b.txt"; git -C "$W" add b.txt; git -C "$W" commit -q -m work
git -C "$W" push -q -u origin feature-x 2>/dev/null
echo '[{"number":7,"state":"MERGED","url":"https://example.test/7","author":{"login":"me"},"mergedAt":"2026-01-01T00:00:00Z","headRefName":"feature-x","headRefOid":"__HEAD__"}]' > "$TMP/pr-merged.json"
export STUB_PR_LIST="$TMP/pr-merged.json"
echo '{}' > "$STATE"

INV() { (cd "$W" && "$ROOT/.claude/scripts/safe-close-inventory.sh" --session "$SESSION" --repo "$REPO" --worktree "$W" --json); }
STOP() { (cd "$W" && "$SCRIPT" "$@"); }
reg() { "$REGISTRY" --repo "$REPO" "$@"; }
jqr() { jq -r "$1" <<<"$OUT"; }

# ---- 1. idle thread: nothing to stop, no menu -----------------------------------------
OUT="$(INV | STOP plan --inventory -)"; rc=$?
[[ $rc == 0 && "$(jqr .nothing_to_stop)" == true && "$(jqr .menu_required)" == false && "$(jqr '.stop_items|length')" == 0 ]] \
  || { echo "$OUT" >&2; fail "idle thread should plan nothing and need no menu"; }
ok "idle thread: nothing to stop, no menu"

# ---- 2. plan classifies this thread's tasks; siblings' never appear ---------------------
echo dirty > "$W/dirty.txt"
reg --register --session "$SESSION" --task-id bash-1 --type bash --name watcher >/dev/null || fail "register bash-1"
reg --register --session "$SESSION" --task-id bash-2 --type bash --name builder --recovery-path "$W" >/dev/null || fail "register bash-2"
reg --register --session "$SESSION" --task-id agent-1 --type agent --name phase-a >/dev/null || fail "register agent-1"
reg --register --session other-sess --task-id theirs-1 --type bash --name theirs >/dev/null || fail "register theirs-1"
OUT="$(INV | STOP plan --inventory -)"
[[ "$(jqr '[.stop_items[].task_id]|sort|join(",")')" == "agent-1,bash-1,bash-2" ]] || { echo "$OUT" >&2; fail "plan did not list exactly this thread's tasks"; }
[[ "$(jqr '.stop_items[]|select(.task_id=="bash-1")|.choice_required')" == false ]] || fail "plain watcher should not need a choice"
[[ "$(jqr '.stop_items[]|select(.task_id=="bash-2")|.unlanded')" == yes ]] || fail "task whose worktree is dirty should be unlanded: yes"
[[ "$(jqr '.stop_items[]|select(.task_id=="agent-1")|.unlanded')" == possible ]] || fail "an agent should be unlanded: possible"
[[ "$(jqr '[.stop_items[]|select(.choice_required)|.default]|unique|join(",")')" == park ]] || fail "default must be park"
[[ "$(jqr '[.stop_items[].offers|index("drop")]|all(. != null)')" == true && "$(jqr '[.stop_items[].default]|index("drop")')" == null ]] || fail "drop must be offered but never the default"
[[ "$(jqr .menu_required)" == true ]] || fail "menu required when something runs"
ok "plan lists this thread's tasks only, flags unlanded work, offers drop but never defaults to it"

# ---- 3. plan never mutates the registry ---------------------------------------------------
before="$(reg --list --session "$SESSION" --live | jq -c '[.[]|{task_id,status}]|sort_by(.task_id)')"
INV | STOP plan --inventory - >/dev/null
after="$(reg --list --session "$SESSION" --live | jq -c '[.[]|{task_id,status}]|sort_by(.task_id)')"
[[ "$before" == "$after" ]] || fail "plan changed the registry"
ok "declining after the plan leaves everything running (plan is read-only)"

# ---- 4. unknown items are listed, never stopped; merge-ready PR gets a wrap offer ----------
SYN="$TMP/syn.json"
jq -n '{items:[
  {category:"subagents",id:".active_agents:a-9",summary:"subagent a-9",consequence:"keeps_running",detail:"",ref:{kind:"state_record",key:"a-9",pr:12,issue:5}},
  {category:"open_prs",id:"pr:12",summary:"PR #12",consequence:"orphaned",detail:"",ref:{kind:"pr",number:12,gate:"merge gate met"}},
  {category:"background_tasks",id:"background_tasks:unknown",summary:"registry unreadable",consequence:"unknown",detail:"",ref:null},
  {category:"ceiling",id:"bgwork:s",summary:"1 marker",consequence:"keeps_running",detail:"",ref:{kind:"bgwork"}}],
  excluded:[{id:"x"},{id:"y"}]}' > "$SYN"
OUT="$(STOP plan --inventory "$SYN")"
[[ "$(jqr '[.stop_items[]|select(.source=="state_record")|.offers|index("wrap")]|first')" != null ]] || { echo "$OUT" >&2; fail "merge-ready PR should offer wrap"; }
[[ "$(jqr '.unknown_items|length')" == 1 && "$(jqr '[.stop_items[]|select(.id|test("unknown"))]|length')" == 0 ]] || fail "unknown item must be listed, not stopped"
[[ "$(jqr '[.stop_items[].source]|sort|join(",")')" == "ceiling,state_record" && "$(jqr .excluded_count)" == 2 ]] || fail "plan sources / excluded count wrong"
jq -n '{items:[
  {category:"harness_tasks",id:"h:1",summary:"background shell h1",consequence:"keeps_running",detail:"",ref:{task_id:"h1",type:"bash"}},
  {category:"linked_sessions",id:"s:1",summary:"session Alpha",consequence:"keeps_running",detail:"",ref:{session_id:"sess-alpha"}},
  {category:"linked_sessions",id:"s:2",summary:"session Beta",consequence:"keeps_running",detail:"",ref:{session_id:"sess-beta"}}],excluded:[]}' > "$SYN"
OUT="$(STOP plan --inventory "$SYN")"
[[ "$(jqr .menu_required)" == true && "$(jqr '[.stop_items[]|select(.kind=="session")]|length')" == 2 ]] || { echo "$OUT" >&2; fail "each linked session must be its own plan item, and alone they still need a menu"; }
[[ "$(jqr '[.stop_items[]|select(.kind=="session")|.default]|unique|join(",")')" == keep && "$(jqr '[.stop_items[]|select(.kind=="session")|.offers|index("park")]|all(. == null)')" == true ]] || fail "linked sessions default to keep and offer no park/drop"
[[ "$(jqr '.stop_items[]|select(.source=="harness")|.task_id')" == h1 ]] || fail "harness-only task missing from the plan"
echo '{"not":"an inventory"}' | STOP plan --inventory - >/dev/null 2>&1; [[ $? == 2 ]] || fail "non-inventory input should exit 2"
ok "unknown items are listed not stopped; merge-ready PR offers wrap; bad input exits 2"

# ---- 5. owner: a babysit watcher is routed to its owner -------------------------------------
jq -n --arg r "$REPO" '{repos:{($r):{prs:{"31":{babysit:{active:true,monitor_task_id:"mon-31"}}}}}}' > "$STATE"
OUT="$(STOP owner --task-id mon-31 --repo "$REPO")"
[[ "$(jqr .owner)" == babysit && "$(jqr .ref)" == 31 ]] || { echo "$OUT" >&2; fail "babysit watcher not identified"; }
OUT="$(STOP owner --task-id mon-zzz --repo "$REPO")"
[[ "$(jqr .owner)" == none ]] || fail "an unnamed task should be owner none"
echo 'not json {' > "$STATE"
STOP owner --task-id mon-31 --repo "$REPO" >/dev/null 2>&1; [[ $? == 3 ]] || fail "unreadable state must be exit 3 (owner unknown)"
echo '{}' > "$STATE"
STOP owner --task-id mon-31 >/dev/null 2>&1; [[ $? == 2 ]] || fail "owner without --repo must be exit 2, never a blind owner none"
# A later read failing (not the first) must also be exit 3: the helper runs in a $( ) subshell, where
# a die would only end the subshell and let the script fall through to owner "none" (a bare TaskStop
# on a named watcher). A stub session-state.sh answers .prs as missing (3) and every other read as 9.
STUBDIR="$TMP/stubstop"; mkdir -p "$STUBDIR"
cp "$SCRIPT" "$STUBDIR/safe-close-stop.sh"
printf '%s\n' '#!/usr/bin/env bash' 'case "$*" in *"--get-json"*) exit 3 ;; *) exit 9 ;; esac' > "$STUBDIR/session-state.sh"
chmod +x "$STUBDIR/session-state.sh"
OUT="$(bash "$STUBDIR/safe-close-stop.sh" owner --task-id mon-31 --repo "$REPO" 2>/dev/null)"; RC=$?
[[ $RC == 3 && -z "$OUT" ]] || fail "a failed later read must be exit 3 with no owner, got rc=$RC out=$OUT"
ok "owner identifies watchers and fails closed on unreadable state"

# ---- 6. park writes the record /go-on reads, and never overwrites an unresumed one ---------
DEC="$TMP/dec.json"
jq -n '{parked:[{kind:"subagent",ref:null,branch:"issue-5-x",head_sha:null,stopped_at:"Phase A in flight (#5)",next_move:"read the handoff and launch Phase B",waiting_on:null,boundary:"unpushed work in worktree",handoff_path:"/h/pr-5.json"}],
        background_tasks_stopped:[{task_id:"bash-2",type:"bash",name:"builder",status:"stopped",recovery_path:"/w"}],monitors_stopped:[]}' > "$DEC"
OUT="$(STOP park --session "$SESSION" --repo "$REPO" --decisions "$DEC")"; rc=$?
[[ $rc == 0 && "$(jqr .parked)" == true ]] || { echo "$OUT" >&2; fail "park did not succeed"; }
MARKER="$(jqr .marker_path)"
[[ -f "$MARKER" && "$(head -1 "$MARKER")" == 'Repository: `acme/widgets`' ]] || fail "marker missing or first line is not the Repository field"
REC="$("$ROOT/.claude/scripts/session-state.sh" --get-json ".repos[\"$REPO\"].pauses[\"$SESSION\"]")"
[[ "$(jq -r '.active' <<<"$REC")" == true && "$(jq -r '.parked|length' <<<"$REC")" == 1 && "$(jq -r '.background_tasks_stopped[0].task_id' <<<"$REC")" == bash-2 ]] || fail "pause record shape wrong: $REC"
[[ "$(jq -r '.refill_paused' <<<"$REC")" == false ]] || fail "safe-close must not close the refill gate"
# The same un-resumed predicate /go-on probe B applies:
jq -e '(.active != false)' >/dev/null <<<"$REC" || fail "record is not un-resumed by /go-on's predicate"
ls "$HOME/.claude/handoffs/"pause-*-4-acme-7-widgets-"$SESSION"-*.md >/dev/null 2>&1 || fail "marker filename is not the injective /pause form"
jq -n '{parked:[{kind:"pr",ref:77,branch:"issue-77-y",stopped_at:"awaiting review (#77)",next_move:"poll",waiting_on:"reviewer",boundary:"pushed"}]}' > "$DEC"
STOP park --session "$SESSION" --repo "$REPO" --decisions "$DEC" >/dev/null || fail "second park failed"
REC="$("$ROOT/.claude/scripts/session-state.sh" --get-json ".repos[\"$REPO\"].pauses[\"$SESSION\"]")"
[[ "$(jq -r '.parked|length' <<<"$REC")" == 2 && "$(jq -r '.background_tasks_stopped|length' <<<"$REC")" == 1 ]] || fail "second park replaced the first board: $REC"
# an unresumed record that carries a refill pause keeps it
jq -n --arg r "$REPO" --arg s "s5" '{repos:{($r):{pauses:{($s):{active:true,session_id:$s,paused_at:"2026-01-01T00:00:00Z",parked:[],monitors_stopped:[],background_tasks_stopped:[],landed:[],refill_paused:true}}}}}' > "$STATE.new"
cp "$STATE" "$STATE.keep"; cp "$STATE.new" "$STATE"
jq -n '{parked:[{kind:"pr",stopped_at:"s",next_move:"n",boundary:"b"}]}' > "$DEC"
STOP park --session s5 --repo "$REPO" --decisions "$DEC" >/dev/null || fail "park onto a record with a refill pause failed"
[[ "$("$ROOT/.claude/scripts/session-state.sh" --get-json ".repos[\"$REPO\"].pauses[\"s5\"].refill_paused")" == true ]] || fail "park dropped an existing refill pause"
cp "$STATE.keep" "$STATE"; rm -f "$STATE.new" "$STATE.keep"
ok "park writes /pause's resumable record + marker, closes no gate, and extends rather than replaces"

# ---- 7. park rejects bad input and fails closed on a write failure ------------------------------
echo '{"parked":[{"kind":"pr"}]}' > "$DEC"
STOP park --session s2 --repo "$REPO" --decisions "$DEC" >/dev/null 2>&1; [[ $? == 2 ]] || fail "incomplete parked entry should exit 2"
echo '{"parked":[]}' > "$DEC"
STOP park --session s2 --repo "$REPO" --decisions "$DEC" >/dev/null 2>&1; [[ $? == 2 ]] || fail "an empty decisions file should exit 2"
[[ "$("$ROOT/.claude/scripts/session-state.sh" --get-json ".repos[\"$REPO\"].pauses[\"s2\"]")" == null ]] || fail "rejected park left a record"
jq -n '{parked:[{kind:"pr",stopped_at:"s",next_move:"n",boundary:"b"}]}' > "$DEC"
mv "$HOME/.claude/handoffs" "$HOME/.claude/handoffs.bak"; : > "$HOME/.claude/handoffs"
STOP park --session s3 --repo "$REPO" --decisions "$DEC" >/dev/null 2>&1; rc=$?
rm -f "$HOME/.claude/handoffs"; mv "$HOME/.claude/handoffs.bak" "$HOME/.claude/handoffs"
[[ $rc == 5 ]] || fail "an unwritable marker directory should exit 5, got $rc"
[[ "$("$ROOT/.claude/scripts/session-state.sh" --get-json ".repos[\"$REPO\"].pauses[\"s3\"]")" == null ]] || fail "failed marker write still recorded state"
ok "park rejects invalid decisions and fails closed (exit 5, no record) when it cannot publish"

# ---- 8. verify: refuses without runtime evidence -----------------------------------------------
STOP verify --session "$SESSION" --repo "$REPO" --worktree "$W" >/dev/null 2>&1; [[ $? == 2 ]] || fail "verify without runtime evidence should exit 2"
ok "verify demands the runtime's own task list"

# ---- 9. verify: a stop that 'succeeded' while the process survives is reported alive ------------
rm -f "$W/dirty.txt"
for t in bash-1 bash-2 agent-1; do
  reg --register --session "$SESSION" --task-id "$t" --type bash --name "$t" >/dev/null || fail "re-register $t"
  reg --transition --session "$SESSION" --task-id "$t" --status stopped >/dev/null || fail "stop $t in the registry"
done
sleep 300 & SPID=$!; SPAWNED="$SPAWNED $SPID"
echo '[]' > "$TMP/live-empty.json"
OUT="$(STOP verify --session "$SESSION" --repo "$REPO" --worktree "$W" --runtime-live-file "$TMP/live-empty.json" --pid "$SPID")"; rc=$?
[[ $rc == 1 && "$OUT" == "Not yet"* && "$OUT" == *"process $SPID is alive"* ]] || { echo "$OUT" >&2; fail "a surviving process was not reported (rc=$rc)"; }
kill "$SPID"; wait "$SPID" 2>/dev/null
OUT="$(STOP verify --session "$SESSION" --repo "$REPO" --worktree "$W" --runtime-live-file "$TMP/live-empty.json" --pid "$SPID")"; rc=$?
[[ $rc == 0 && "$(echo "$OUT" | head -1)" == "Nothing owned by this thread is still running." ]] || { echo "$OUT" >&2; fail "a reaped process should verify clean (rc=$rc)"; }
ok "a live pid is reported still running; once reaped the thread verifies clean"

# ---- 10. verify: registry says stopped but the runtime still lists the task ------------------------
printf 'bash-1\n' > "$TMP/live-bash1.txt"
OUT="$(STOP verify --session "$SESSION" --repo "$REPO" --worktree "$W" --runtime-live-file "$TMP/live-bash1.txt" --stopped-id bash-1 --stopped-id bash-2)"; rc=$?
[[ $rc == 1 && "$OUT" == *"bash-1"*"did not take effect"* && "$OUT" != *"bash-2:"* ]] || { echo "$OUT" >&2; fail "task still in the runtime list was not reported (rc=$rc)"; }
OUT="$(STOP verify --session "$SESSION" --repo "$REPO" --worktree "$W" --runtime-live-file "$TMP/live-bash1.txt")"; rc=$?
[[ $rc == 1 && "$OUT" == *"bash-1"* ]] || { echo "$OUT" >&2; fail "a registered id the runtime still lists must count even when not named with --stopped-id (rc=$rc)"; }
: > "$TMP/live-blank.txt"
STOP verify --session "$SESSION" --repo "$REPO" --worktree "$W" --runtime-live-file "$TMP/live-blank.txt" >/dev/null 2>&1; [[ $? == 3 ]] || fail "an empty runtime file must be a failed read (exit 3), not an empty list"
OUT="$(STOP verify --session "$SESSION" --repo "$REPO" --worktree "$W" --runtime-unreadable)"; rc=$?
[[ $rc == 1 && "$OUT" == *"[unverified]"* && "$OUT" == *"bash-1"* ]] || { echo "$OUT" >&2; fail "registry-stopped ids must be unverified when the runtime list is unreadable, even without --stopped-id (rc=$rc)"; }
OUT="$(STOP verify --session "$SESSION" --repo "$REPO" --worktree "$W" --runtime-unreadable --stopped-id bash-1)"; rc=$?
[[ $rc == 1 && "$OUT" == *"[unverified]"* ]] || { echo "$OUT" >&2; fail "unreadable runtime list must leave stopped ids unverified"; }
ok "a success status is not proof: the runtime list decides; an unreadable list is unverified"

# ---- 11. verify: a subagent record stays running until its runtime id is confirmed gone ---------------
jq -n --arg s "$SESSION" '{active_agents:{"a-1":{id:"a-1",session_id:$s,status:"spawned"}}}' > "$STATE"
OUT="$(STOP verify --session "$SESSION" --repo "$REPO" --worktree "$W" --runtime-live-file "$TMP/live-empty.json")"; rc=$?
[[ $rc == 1 && "$OUT" == *"a-1"* ]] || { echo "$OUT" >&2; fail "unconfirmed subagent record should stay running"; }
OUT="$(STOP verify --session "$SESSION" --repo "$REPO" --worktree "$W" --runtime-live-file "$TMP/live-empty.json" --confirmed-gone a-1)"; rc=$?
[[ $rc == 0 ]] || { echo "$OUT" >&2; fail "confirmed-gone subagent should verify clean (rc=$rc)"; }
printf 'a-1\n' > "$TMP/live-a1.txt"
STOP verify --session "$SESSION" --repo "$REPO" --worktree "$W" --runtime-live-file "$TMP/live-a1.txt" --confirmed-gone a-1 >/dev/null; [[ $? == 1 ]] || fail "confirmed-gone must not clear a record the runtime list still names"
STOP verify --session "$SESSION" --repo "$REPO" --worktree "$W" --runtime-unreadable --confirmed-gone a-1 >/dev/null; [[ $? == 1 ]] || fail "confirmed-gone must not clear a record when the runtime list was unreadable"
ok "subagent records need the harness to confirm the runtime id is gone"

# ---- 12. verify: sibling thread's work is never counted; unknown items are unverified ---------------------
jq -n '{active_agents:{"a-2":{id:"a-2",session_id:"other-sess",status:"spawned"}}}' > "$STATE"
OUT="$(STOP verify --session "$SESSION" --repo "$REPO" --worktree "$W" --runtime-live-file "$TMP/live-empty.json")"; rc=$?
[[ $rc == 0 ]] || { echo "$OUT" >&2; fail "another thread's subagent counted against this thread"; }
echo 'not json {' > "$STATE"
OUT="$(STOP verify --session "$SESSION" --repo "$REPO" --worktree "$W" --runtime-live-file "$TMP/live-empty.json" 2>/dev/null)"; rc=$?
[[ ( $rc == 1 || $rc == 3 ) && "$OUT" != "Nothing owned"* ]] || { echo "$OUT" >&2; fail "unreadable state must never verify clean (rc=$rc)"; }
echo '{}' > "$STATE"
ok "sibling thread's subagent is untouched and uncounted; unreadable state is never clean"

# ---- 13. clear-ceiling: only once no Monitor is live ---------------------------------------------------
CEIL="$ROOT/.claude/scripts/bgwork-ceiling.sh"
"$CEIL" --note-started subagent --session "$SESSION" >/dev/null 2>&1
reg --register --session "$SESSION" --task-id mon-9 --type monitor --name ceiling >/dev/null || fail "register mon-9"
reg --register --session "$SESSION" --task-id bash-9 --type bash --name other >/dev/null || fail "register bash-9"
STOP clear-ceiling --session "$SESSION" --repo "$REPO" >/dev/null 2>&1; rc=$?
[[ $rc == 1 ]] || fail "ceiling cleared while a Monitor was live (rc=$rc)"
[[ "$("$CEIL" --status --session "$SESSION" | jq -r '.background_work|length')" -ge 1 ]] || fail "ceiling markers were removed anyway"
reg --transition --session "$SESSION" --task-id mon-9 --status stopped >/dev/null
STOP clear-ceiling --session "$SESSION" --repo "$REPO" >/dev/null 2>&1; [[ $? == 1 ]] || fail "ceiling cleared while a non-Monitor task was still live"
reg --transition --session "$SESSION" --task-id bash-9 --status stopped >/dev/null
OUT="$(STOP clear-ceiling --session "$SESSION" --repo "$REPO")"; rc=$?
[[ $rc == 0 && "$("$CEIL" --status --session "$SESSION" | jq -r '.background_work|length')" == 0 ]] || { echo "$OUT" >&2; fail "ceiling not cleared once the Monitor was stopped (rc=$rc)"; }
ok "ceiling markers are cleared only once no task of any kind is live"

# ---- 14. the inventory script stays read-only ------------------------------------------------------------
CODE="$(grep -v '^[[:space:]]*#' "$ROOT/.claude/scripts/safe-close-inventory.sh")"
if grep -Eq 'TaskStop|(^|[^a-z_])kill |--clear|--transition|--set |(^|[^a-z_])rm -' <<<"$CODE"; then
  fail "inventory script grew a stop or write path"
fi
ok "stop logic lives outside the read-only inventory script"

echo "all safe-close-stop tests passed"
