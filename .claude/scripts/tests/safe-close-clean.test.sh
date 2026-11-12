#!/usr/bin/env bash
# catalog: tests — Tests for `safe-close-clean.sh`: finished work removed through the existing helpers, work-holding things kept, other threads' entries untouched, unreadable reads never counted as cleaned, and a read-back instead of an exit status
#
# Builds its own fixtures (fake HOME, a private copy of the scripts directory with
# stubbed `gh`, `issue-claim.sh` and `workspace-sweep.sh`, throwaway git repos and
# worktrees) so it never touches real session state, GitHub, claims, worktrees or
# anyone's processes. Run from the repo root.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

fail() {
  echo "FAIL: $*" >&2
  [[ -n "${OUT:-}" ]] && echo "$OUT" >&2
  [[ -n "${DUMP_STATE:-}" ]] && cat "$STATE" >&2
  exit 1
}
ok() { echo "ok   — $*"; }

export HOME="$TMP/home"
mkdir -p "$HOME/.claude" "$TMP/bin" "$TMP/stub" "$TMP/claims"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
REPO=acme/widgets
SESSION=sess-1
STATE="$HOME/.claude/session-state.json"
export STUB_DIR="$TMP/stub" CLAIM_DIR="$TMP/claims" SWEEP_LOG="$TMP/sweep.log" SWEEP_LIST="$TMP/sweep.list"

# A private copy of the scripts: the cleaner resolves its helpers next to itself first, so the
# stubs below stand in for the two helpers that need GitHub or a real finished-work sweep.
S="$TMP/.claude/scripts"
mkdir -p "$TMP/.claude"
cp -R "$ROOT/.claude/scripts" "$S" || fail "could not copy the scripts directory"
cp -R "$ROOT/.claude/reference" "$TMP/.claude/reference" || fail "could not copy the reference directory (session-state.sh reads its schema from there)"
SCRIPT="$S/safe-close-clean.sh"

cat > "$S/issue-claim.sh" <<'EOF'
#!/usr/bin/env bash
n="$1"; shift; mode=""; holder=""
while [[ $# -gt 0 ]]; do
  case "$1" in --check|--release|--claim) mode="$1" ;; --holder) holder="$2"; shift ;; --repo) shift ;; esac
  shift
done
f="$CLAIM_DIR/$n"
case "$mode" in
  --check)
    if [[ -f "$f" ]]; then
      h="$(cat "$f")"; v=claimed; [[ "$h" == "$holder" ]] && v=mine
      printf '{"verdict":"%s","claimant_holder":"%s"}\n' "$v" "$h"; [[ "$v" == mine ]]
    else echo '{"verdict":"unclaimed"}'; fi ;;
  --release) [[ -n "${STUB_CLAIM_RELEASE_FAILS:-}" ]] && exit 0; rm -f "$f"; echo '{"verdict":"unclaimed"}' ;;
esac
EOF
cat > "$S/workspace-sweep.sh" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$SWEEP_LOG"
# SWEEP_LIST lines: "<path> <branch>" — what this stub "finds finished" and removes with plain git.
if [[ -f "$SWEEP_LIST" ]]; then
  while read -r p b; do
    [[ -n "$p" ]] || continue
    git -C "$STUB_MAIN" worktree remove "$p" >/dev/null 2>&1 && git -C "$STUB_MAIN" branch -D "$b" >/dev/null 2>&1
  done < "$SWEEP_LIST"
fi
exit "${STUB_SWEEP_EXIT:-0}"
EOF
chmod +x "$S/issue-claim.sh" "$S/workspace-sweep.sh"

cat > "$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
  "api user") echo me ;;
  "pr list") [[ -f "$STUB_DIR/prlist-fail" ]] && exit 1; cat "$STUB_DIR/prlist.json" ;;
  "pr view") f="$STUB_DIR/prview-$3.json"; [[ -f "$f" ]] && cat "$f" || exit 1 ;;
  "issue list") echo '[]' ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH"

git init -q --bare "$TMP/origin.git"
git clone -q "$TMP/origin.git" "$TMP/work" 2>/dev/null
git -C "$TMP/work" checkout -q -b main
echo a > "$TMP/work/a.txt"; git -C "$TMP/work" add a.txt; git -C "$TMP/work" commit -q -m base
git -C "$TMP/work" push -q -u origin main 2>/dev/null
git -C "$TMP/work" checkout -q -b issue-9-own
W="$(cd "$TMP/work" && pwd -P)"
export STUB_MAIN="$W"
echo '[]' > "$STUB_DIR/prlist.json"
echo '{}' > "$STATE"

INVJ() { jq -n --arg s "${2:-$SESSION}" --arg r "$REPO" --arg w "$W" --argjson items "$1" \
  '{schema_version:1, verdict:"not_yet", outstanding:0, session:$s, repo:$r, worktree:$w, categories:{}, items:$items, excluded:[], agent_checks:[]}'; }
CLEAN() { (cd "$W" && "$SCRIPT" "$1" --inventory - --session "$SESSION" --repo "$REPO" --worktree "$W" "${@:2}"); }
jqr() { jq -r "$1" <<<"$OUT"; }
claim_item() { printf '{"category":"claims","id":"claim:%s","summary":"s","consequence":"orphaned","detail":"d","ref":{"kind":"claim","issue":%s}}' "$1" "$1"; }
handoff_item() { printf '{"category":"handoffs","id":"handoff:%s","summary":"s","consequence":"harmless","detail":"d","ref":{"kind":"handoff","path":"%s"}}' "$1" "$("$S/handoff-state.sh" --owner-repo "$REPO" --path "$1")"; }
prview() { printf '{"number":%s,"state":"%s","author":{"login":"%s"}}' "$1" "$2" "${3:-me}" > "$STUB_DIR/prview-$1.json"; }

# ---- 1. required arguments and attribution -------------------------------------------------------
for missing in "--session" "--repo" "--worktree"; do
  case "$missing" in
    --session) args=(--repo "$REPO" --worktree "$W") ;;
    --repo) args=(--session "$SESSION" --worktree "$W") ;;
    --worktree) args=(--session "$SESSION" --repo "$REPO") ;;
  esac
  OUT="$(INVJ '[]' | (cd "$W" && "$SCRIPT" plan --inventory - "${args[@]}") 2>&1)"; rc=$?
  [[ $rc == 2 ]] || fail "a missing $missing must exit 2, got $rc"
done
OUT="$(INVJ '[]' other-sess | CLEAN plan 2>&1)"; rc=$?
[[ $rc == 2 ]] || fail "an inventory for another session must be refused (exit 2), got $rc"
OUT="$(echo '{"foo":1}' | CLEAN plan 2>&1)"; rc=$?
[[ $rc == 2 ]] || fail "a non-inventory document must be refused (exit 2), got $rc"
OUT="$(INVJ '[]' | CLEAN apply --approve nonsense 2>&1)"; rc=$?
[[ $rc == 2 ]] || fail "an unknown --approve kind must exit 2"
ok "session, repo and worktree are required; a foreign or malformed inventory is refused"

# ---- 2. nothing to clean: a no-op ------------------------------------------------------------------
OUT="$(INVJ '[]' | CLEAN apply)"; rc=$?
[[ $rc == 0 && "$(jqr '.removed|length')" == 0 && "$(jqr '.kept|length')" == 0 && "$(jqr .verdict)" == not_assessed ]] || fail "empty inventory should be a no-op that states no verdict"
[[ ! -s "$SWEEP_LOG" ]] || fail "the sweep ran with nothing of this thread's to sweep"
ok "an already-clean thread is a no-op, runs no sweep and states no verdict"

# ---- 3. claims -------------------------------------------------------------------------------------------
echo "$SESSION" > "$CLAIM_DIR/5"; echo "$SESSION" > "$CLAIM_DIR/6"; echo "someone-else" > "$CLAIM_DIR/8"
echo '[{"number":61,"headRefName":"issue-6-open-pr","closingIssuesReferences":[]}]' > "$STUB_DIR/prlist.json"
ITEMS="[$(claim_item 5),$(claim_item 6),$(claim_item 8)]"
OUT="$(INVJ "$ITEMS" | CLEAN plan)"
[[ -f "$CLAIM_DIR/5" && "$(jqr '.would_remove|map(.id)|join(",")')" == "issue #5" ]] || fail "plan must only name claim 5, and write nothing"
OUT="$(INVJ "$ITEMS" | CLEAN apply)"; rc=$?
[[ $rc == 0 ]] || fail "apply of claims should exit 0, got $rc"
[[ ! -f "$CLAIM_DIR/5" ]] || fail "the claim with no open PR was not released"
[[ -f "$CLAIM_DIR/6" ]] || fail "a claim on an issue with an open PR must be kept"
[[ "$(cat "$CLAIM_DIR/8")" == "someone-else" ]] || fail "another holder's claim must be untouched"
[[ "$(jqr '[.kept[]|select(.id=="issue #6")]|length')" == 1 ]] || fail "the kept claim must be named"
ok "a claim with no open PR is released; one with an open PR and a foreign holder's are kept"
# a PR that closes the issue (not by branch name) also keeps the claim
echo "$SESSION" > "$CLAIM_DIR/5"
echo '[{"number":62,"headRefName":"feature-x","closingIssuesReferences":[{"number":5}]}]' > "$STUB_DIR/prlist.json"
OUT="$(INVJ "[$(claim_item 5)]" | CLEAN apply)"
[[ -f "$CLAIM_DIR/5" ]] || fail "a closing reference from an open PR must keep the claim"
ok "an open PR that closes the issue keeps the claim"
# unreadable open-PR list: keep everything and report a failure
echo '[]' > "$STUB_DIR/prlist.json"; touch "$STUB_DIR/prlist-fail"
OUT="$(INVJ "[$(claim_item 5)]" | CLEAN apply)"; rc=$?
[[ $rc == 1 && -f "$CLAIM_DIR/5" && "$(jqr '.failed|length')" -ge 1 && "$(jqr '.removed|length')" == 0 ]] || fail "an unreadable open-PR list must keep the claim, report failed, exit 1"
rm -f "$STUB_DIR/prlist-fail"
ok "an unreadable open-PR list keeps the claim and is reported, not skipped"
# release that does nothing is not success
OUT="$(INVJ "[$(claim_item 5)]" | STUB_CLAIM_RELEASE_FAILS=1 CLEAN apply)"; rc=$?
[[ $rc == 1 && "$(jqr '.removed|length')" == 0 && "$(jqr '.failed|length')" == 1 ]] || fail "a release that left the claim must be failed, not removed"
ok "a release that changes nothing is read back and reported failed"
rm -f "$CLAIM_DIR"/*

# ---- 4. handoffs ------------------------------------------------------------------------------------------
for n in 7 8 9 10; do "$S/handoff-state.sh" --owner-repo "$REPO" --create "$n" "{\"schema_version\":\"1.0\",\"pr_number\":$n}"; done
prview 7 MERGED; prview 8 OPEN; prview 10 MERGED someone-else   # 9 has no PR record: unreadable
ITEMS="[$(handoff_item 7),$(handoff_item 8),$(handoff_item 9),$(handoff_item 10)]"
H7="$("$S/handoff-state.sh" --owner-repo "$REPO" --path 7)"; H8="$("$S/handoff-state.sh" --owner-repo "$REPO" --path 8)"
H9="$("$S/handoff-state.sh" --owner-repo "$REPO" --path 9)"; H10="$("$S/handoff-state.sh" --owner-repo "$REPO" --path 10)"
OUT="$(INVJ "$ITEMS" | CLEAN plan)"
[[ -f "$H7" && "$(jqr '.would_remove|length')" == 1 ]] || fail "plan must only name the merged handoff and delete nothing"
OUT="$(INVJ "$ITEMS" | CLEAN apply)"; rc=$?
[[ ! -e "$H7" ]] || fail "the handoff of a merged PR was not deleted"
[[ -e "$H8" ]] || fail "the handoff of an OPEN PR must be kept"
[[ -e "$H9" ]] || fail "a handoff whose PR state is unreadable must be kept"
[[ -e "$H10" ]] || fail "a handoff for a PR this account did not author must be kept"
[[ $rc == 1 && "$(jqr '.failed|length')" == 1 ]] || fail "the unreadable PR must be a reported failure (exit 1), got rc=$rc"
ok "handoffs are deleted only for merged PRs this account authored; open, unreadable and foreign ones are kept"

# ---- 5. worktrees and the finished-work sweep ------------------------------------------------------------
git -C "$W" worktree add -q -b agent-done "$TMP/wt-done" 2>/dev/null
git -C "$W" worktree add -q -b agent-held "$TMP/wt-held" 2>/dev/null
git -C "$W" worktree add -q -b agent-dirty "$TMP/wt-dirty" 2>/dev/null
echo x > "$TMP/wt-dirty/new.txt"
WD="$(cd "$TMP/wt-done" && pwd -P)"; WH="$(cd "$TMP/wt-held" && pwd -P)"; WX="$(cd "$TMP/wt-dirty" && pwd -P)"
wt_item() { printf '{"category":"worktrees","id":"%s:%s","summary":"%s","consequence":"%s","detail":"d","ref":{"kind":"worktree","path":"%s","branch":"%s"}}' "$1" "$2" "$5" "$3" "$2" "$4"; }
ITEMS="[$(wt_item clean "$W" harmless issue-9-own 'own'),$(wt_item clean "$WD" harmless agent-done 'done'),$(wt_item clean "$WH" harmless agent-held 'held'),$(wt_item dirty "$WX" lost agent-dirty '1 uncommitted path')]"
echo "$WD agent-done" > "$SWEEP_LIST"
: > "$SWEEP_LOG"
OUT="$(INVJ "$ITEMS" | CLEAN plan)"
[[ ! -s "$SWEEP_LOG" && -d "$WD" ]] || fail "plan must not run the sweep"
OUT="$(INVJ "$ITEMS" | CLEAN apply)"; rc=$?
[[ -s "$SWEEP_LOG" ]] || fail "the finished-work sweep was not run"
grep -q -- "--repo-dir $W" "$SWEEP_LOG" || fail "the sweep must run from the thread's own checkout"
[[ ! -d "$WD" ]] || fail "the finished worktree was not removed"
[[ -d "$WH" && -d "$WX" && -d "$W" ]] || fail "unfinished, dirty and own checkouts must remain"
[[ "$(jqr '[.removed[]|select(.kind=="worktree")|.id]|join(",")')" == "$WD" ]] || fail "only the finished worktree may be reported removed"
[[ "$(jqr '[.kept[]|select(.kind=="worktree")|.id]|sort|join(",")')" == "$(printf '%s\n' "$WH" "$WX" | LC_ALL=C sort | paste -sd, -)" ]] || fail "the retained and dirty worktrees must be named as kept"
[[ "$(jqr '[.kept[]|select(.id=="'"$WX"'")|.pickup]|.[0]')" == *"commit and push"* ]] || fail "the dirty worktree needs a pickup note"
git -C "$W" show-ref --verify --quiet refs/heads/agent-done && fail "the finished worktree's local branch should be gone"
git -C "$W" show-ref --verify --quiet refs/heads/agent-dirty || fail "the dirty worktree's branch must remain"
ok "finished worktree and branch go through the sweep; held, dirty and own checkouts are kept and named"
# the sweep's exit status is not proof
git -C "$W" worktree add -q -b agent-done2 "$TMP/wt-done2" 2>/dev/null
WD2="$(cd "$TMP/wt-done2" && pwd -P)"
: > "$SWEEP_LIST"
OUT="$(INVJ "[$(wt_item clean "$WD2" harmless agent-done2 x)]" | STUB_SWEEP_EXIT=0 CLEAN apply)"
[[ -d "$WD2" && "$(jqr '.removed|length')" == 0 && "$(jqr '.kept|length')" == 1 ]] || fail "exit 0 from a sweep that removed nothing must not be reported as removed"
echo "$WD2 agent-done2" > "$SWEEP_LIST"
OUT="$(INVJ "[$(wt_item clean "$WD2" harmless agent-done2 x)]" | STUB_SWEEP_EXIT=1 CLEAN apply)"
[[ ! -d "$WD2" && "$(jqr '.removed|map(.kind)|index("worktree")')" != null ]] || fail "a sweep exiting 1 that removed the tree must be reported from the read-back"
ok "removal is read back from git, never taken from the sweep's exit status"
# own checkout only: no sweep, one note
: > "$SWEEP_LOG"
OUT="$(INVJ "[$(wt_item clean "$W" harmless issue-9-own own)]" | CLEAN apply)"
[[ ! -s "$SWEEP_LOG" && "$(jqr '.notes|map(.kind)|index("own_checkout")')" != null ]] || fail "only the thread's own checkout: no sweep, one note"
ok "the thread's own checkout is never swept and is explained"
git -C "$W" worktree remove --force "$TMP/wt-held" 2>/dev/null; git -C "$W" worktree remove --force "$TMP/wt-dirty" 2>/dev/null

# ---- 6. session-state: this session's entries only ----------------------------------------------------------
agent_item() { printf '{"category":"subagents","id":".active_agents:%s","summary":"s","consequence":"keeps_running","detail":"d","ref":{"kind":"state_record","path":".active_agents","key":"%s"}}' "$1" "$1"; }
marker_item() { jq -nc --arg p "$1" '{category:"state_markers",id:$p,summary:"s",consequence:"orphaned",detail:"d",ref:{kind:"state_marker",path:$p}}'; }
jq -n --arg r "$REPO" --arg s "$SESSION" '{
  active_agents:{gone1:{session_id:$s}, live1:{session_id:$s}, theirs:{session_id:"other"}, foreignmine:{session_id:"other"}},
  repos:{($r):{resumes:{($s):{at:"x"}, other:{at:"y"}}, pauses:{($s):{active:true,resumed_at:null,parked:[{kind:"pr"}]}, other:{active:true,resumed_at:null}},
              execution_pauses:{other:{active:true}}}}}' > "$STATE"
before_other="$(jq -cS '[.active_agents.theirs, .active_agents.foreignmine, .repos["acme/widgets"].resumes.other, .repos["acme/widgets"].pauses.other, .repos["acme/widgets"].execution_pauses.other]' "$STATE")"
ITEMS="[$(agent_item gone1),$(agent_item live1),$(agent_item foreignmine),$(marker_item '.resumes'),$(marker_item '.pauses')]"
sum_before="$(cksum < "$STATE")"
OUT="$(INVJ "$ITEMS" | CLEAN plan --confirmed-gone gone1 --confirmed-gone foreignmine)"
[[ "$(cksum < "$STATE")" == "$sum_before" ]] || fail "plan must not change the state file"
OUT="$(INVJ "$ITEMS" | CLEAN apply --confirmed-gone gone1 --confirmed-gone foreignmine)"; rc=$?
[[ "$(jq -r '.active_agents.gone1' "$STATE")" == null ]] || fail "a confirmed-gone agent record of this session must be removed"
[[ "$(jq -r '.active_agents.live1.session_id' "$STATE")" == "$SESSION" ]] || fail "an agent not confirmed gone must be kept"
[[ "$(jq -r '.active_agents.foreignmine.session_id' "$STATE")" == other ]] || fail "a record naming another session must not be removed even when named as gone"
[[ "$(jq -r '.repos["acme/widgets"].resumes["sess-1"]' "$STATE")" == null ]] || fail "this session's resume receipt must be cleared"
[[ "$(jq -cS '[.active_agents.theirs, .active_agents.foreignmine, .repos["acme/widgets"].resumes.other, .repos["acme/widgets"].pauses.other, .repos["acme/widgets"].execution_pauses.other]' "$STATE")" == "$before_other" ]] \
  || fail "another thread's state entries must be byte-identical after cleanup"
[[ "$(jq -r '.repos["acme/widgets"].pauses["sess-1"].active' "$STATE")" == true ]] || fail "an un-resumed park record must not be cleared without approval"
[[ "$(jqr '[.ask[]|.approve]|join(",")')" == pause_record ]] || fail "the park record must go to the ask list"
ok "agent records need a confirmed-gone; the resume receipt is cleared; the park record asks; another thread's entries are byte-identical"
OUT="$(INVJ "$ITEMS" | CLEAN apply --approve pause_record)"
[[ "$(jq -r '.repos["acme/widgets"].pauses["sess-1"].active' "$STATE")" == false && "$(jq -r '.repos["acme/widgets"].pauses["sess-1"].parked|length' "$STATE")" == 1 ]] \
  || fail "an approved park record must be closed without losing its content"
[[ "$(jq -cS '[.repos["acme/widgets"].pauses.other, .repos["acme/widgets"].resumes.other]' "$STATE")" == "$(jq -cn '[{active:true,resumed_at:null},{at:"y"}]' | jq -cS .)" ]] || fail "the other session's records changed"
ok "an approved park record is closed (content kept), nothing else moves"

# launch gate through execution-pause.sh
echo '{}' > "$STATE"
"$S/execution-pause.sh" --repo "$REPO" --activate --session "$SESSION" --command pause --window-minutes 15 >/dev/null 2>&1 || fail "could not arm the fixture's launch gate"
"$S/execution-pause.sh" --repo "$REPO" --activate --session other --command pause --window-minutes 15 >/dev/null 2>&1 || fail "could not arm the other session's gate"
OUT="$(INVJ "[$(marker_item '.execution_pauses')]" | CLEAN apply)"
[[ "$("$S/execution-pause.sh" --repo "$REPO" --status --session "$SESSION")" == active && "$(jqr '[.ask[]|.approve]|join(",")')" == launch_gate ]] || fail "an armed launch gate must ask, not clear"
OUT="$(INVJ "[$(marker_item '.execution_pauses')]" | CLEAN apply --approve launch_gate)"
[[ "$("$S/execution-pause.sh" --repo "$REPO" --status --session "$SESSION")" == inactive ]] || fail "the approved launch gate was not cleared"
[[ "$("$S/execution-pause.sh" --repo "$REPO" --status --session other)" == active ]] || fail "another session's launch gate was cleared"
ok "a launch gate asks first; once approved it is cleared through execution-pause.sh and only for this session"

# leave marker
jq -n --arg r "$REPO" --arg s "$SESSION" '{repos:{($r):{leave:{active:true,session_id:$s,winddown_task_id:null}}}}' > "$STATE"
OUT="$(INVJ "[$(marker_item '.repos["acme/widgets"].leave')]" | CLEAN apply)"
[[ "$(jq -r '.repos["acme/widgets"].leave.active' "$STATE")" == true && "$(jqr '[.ask[]|.approve]|join(",")')" == leave ]] || fail "an armed leave marker must ask"
OUT="$(INVJ "[$(marker_item '.repos["acme/widgets"].leave')]" | CLEAN apply --approve leave)"
[[ "$(jq -r '.repos["acme/widgets"].leave.active' "$STATE")" == false ]] || fail "the approved leave marker was not cleared"
jq -n --arg r "$REPO" --arg s "$SESSION" '{repos:{($r):{leave:{active:true,session_id:$s,winddown_task_id:"task-9"}}}}' > "$STATE"
OUT="$(INVJ "[$(marker_item '.repos["acme/widgets"].leave')]" | CLEAN apply --approve leave)"
[[ "$(jq -r '.repos["acme/widgets"].leave.active' "$STATE")" == true && "$(jqr '.kept|length')" == 1 ]] || fail "a leave marker naming a wind-down Monitor must be kept even when approved"
ok "a leave marker asks first; one that still names its wind-down Monitor is kept"

# unreadable state is a failure, never a clean no-op
echo '{not json' > "$STATE"
OUT="$(INVJ "[$(marker_item '.resumes')]" | CLEAN apply)"; rc=$?
[[ $rc == 1 && "$(jqr '.removed|length')" == 0 ]] || fail "an unreadable session-state must be reported as failed (exit 1), not skipped"
for k in resumes pauses execution_pauses; do
  [[ "$(jqr "[.failed[]|select(.kind==\"$k\")]|length")" == 2 ]] || fail "the unreadable $k maps (top-level and repo-scoped) must each be reported failed"
done
[[ "$(jqr '[.failed[]|select(.kind=="leave")]|length')" == 2 ]] || fail "the unreadable leave markers must each be reported failed"
echo '{}' > "$STATE"
ok "an unreadable session-state is reported failed and nothing is claimed cleaned"

# ---- 7. scratch files ----------------------------------------------------------------------------------------
SCR="$TMP/pad/scratchpad"; mkdir -p "$SCR/sub"
echo a > "$SCR/a.txt"; echo b > "$SCR/sub/b.txt"; echo SECRET=1 > "$SCR/.env"; ln -s "$TMP/work/a.txt" "$SCR/link"
scratch_item() { printf '{"category":"scratchpad","id":"scratch:%s","summary":"s","consequence":"harmless","detail":"d","ref":{"kind":"scratchpad","path":"%s"}}' "$1" "$1"; }
OUT="$(INVJ "[$(scratch_item "$SCR")]" | CLEAN plan --scratchpad "$SCR")"
[[ -f "$SCR/a.txt" ]] || fail "plan must not delete scratch"
OUT="$(INVJ "[$(scratch_item "$SCR")]" | CLEAN apply --scratchpad "$SCR")"; rc=$?
[[ $rc == 0 && ! -e "$SCR/a.txt" && ! -e "$SCR/sub/b.txt" ]] || fail "regular scratch files were not removed"
[[ -f "$SCR/.env" ]] || fail ".env* files must be kept"
[[ -L "$SCR/link" && -f "$TMP/work/a.txt" ]] || fail "a symlink must be kept and its target untouched"
ok "scratch files are removed; .env files and links are kept and the link target is untouched"
OUT="$(INVJ "[$(scratch_item "$SCR")]" | CLEAN apply --scratchpad "$TMP/other")"; rc=$?
[[ $rc == 1 && "$(jqr '.failed|length')" == 1 ]] || fail "a scratchpad that is not the one named must fail"
mkdir -p "$TMP/repo-like/x/y"; git init -q "$TMP/repo-like/x/y"; echo k > "$TMP/repo-like/x/y/keep.txt"
OUT="$(INVJ "[$(scratch_item "$TMP/repo-like/x/y")]" | CLEAN apply --scratchpad "$TMP/repo-like/x/y")"; rc=$?
[[ $rc == 1 && -f "$TMP/repo-like/x/y/keep.txt" ]] || fail "a git checkout must never be treated as a scratchpad"
ok "a mismatched scratchpad and a git checkout are refused"
SCR2="$TMP/pad2/scratchpad"; mkdir -p "$SCR2/proj/.git"; echo k > "$SCR2/proj/keep.txt"; echo a > "$SCR2/a.txt"
OUT="$(INVJ "[$(scratch_item "$SCR2")]" | CLEAN apply --scratchpad "$SCR2")"; rc=$?
[[ $rc == 1 && -f "$SCR2/proj/keep.txt" && -f "$SCR2/a.txt" && "$(jqr '.removed|length')" == 0 ]] || fail "a git checkout nested in the scratchpad must stop the cleanup with nothing deleted"
ok "a git checkout nested inside the scratchpad stops the cleanup before anything is deleted"

# ---- 8. end to end with the real inventory: the re-run is the verdict ---------------------------------------------
echo '{}' > "$STATE"
git -C "$TMP/work" checkout -q -b feature-e2e
echo b > "$TMP/work/b.txt"; git -C "$TMP/work" add b.txt; git -C "$TMP/work" commit -q -m work
git -C "$TMP/work" push -q -u origin feature-e2e 2>/dev/null
echo "[{\"number\":7,\"state\":\"MERGED\",\"url\":\"https://example.test/7\",\"author\":{\"login\":\"me\"},\"mergedAt\":\"2026-01-01T00:00:00Z\",\"headRefName\":\"feature-e2e\",\"headRefOid\":\"$(git -C "$TMP/work" rev-parse HEAD)\"}]" > "$STUB_DIR/prlist.json"
jq -n --arg r "$REPO" --arg s "$SESSION" '{repos:{($r):{resumes:{($s):{at:"x"}}}}}' > "$STATE"
RUNINV() { (cd "$W" && "$S/safe-close-inventory.sh" --session "$SESSION" --repo "$REPO" --worktree "$W" --json); }
OUT="$(RUNINV)"
[[ "$(jqr .verdict)" == not_yet ]] || fail "the leftover resume receipt should hold the verdict at not_yet"
echo "$OUT" | CLEAN apply >/dev/null
OUT="$(RUNINV)"
[[ "$(jqr .verdict)" == safe ]] || fail "after cleanup the re-run should read safe"
ok "end to end: the inventory says not yet, cleanup runs, the re-run says safe"
# a marker the cleanup could not clear (corrupt state) keeps the re-run at not-yet
echo '{not json' > "$STATE"
OUT="$(RUNINV)"
[[ "$(jqr .verdict)" == not_yet ]] || fail "an unreadable session-state must never re-run as safe"
ok "an unreadable state can never re-run as safe"

# ---- 9. --help ---------------------------------------------------------------------------------------------------------
OUT="$("$SCRIPT" --help)"
[[ "$OUT" == *"safe-close-clean.sh plan"* ]] || fail "--help should print the usage header"
"$SCRIPT" bogus >/dev/null 2>&1; [[ $? == 2 ]] || fail "an unknown mode must exit 2"
ok "--help and usage errors"
echo "all safe-close-clean tests passed"
