#!/usr/bin/env bash
# catalog: tests — Tests for `safe-close-inventory.sh`: verdicts, consequence tags, unknown-forces-not-yet, exclusion of other threads, and read-only behaviour
#
# Builds its own fixtures (fake HOME, throwaway repos, a stub `gh`) so it never
# touches real session state or GitHub. Run from the repo root.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SCRIPT="$ROOT/.claude/scripts/safe-close-inventory.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok   — $*"; }

export HOME="$TMP/home"
mkdir -p "$HOME/.claude" "$TMP/bin"
# The inventory reads session transcripts from CLAUDE_CONFIG_DIR when set: pin it to the fixture.
export CLAUDE_CONFIG_DIR="$HOME/.claude"
# Read bgwork markers from this suite's own directory, not the shared /tmp (issue #2391).
export CLAUDE_BGWORK_MARKER_DIR="$TMP/markers"; mkdir -p "$CLAUDE_BGWORK_MARKER_DIR"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
REPO=acme/widgets
SESSION=sess-1
STATE="$HOME/.claude/session-state.json"

# ---- stub gh: api user, pr list, pr view; everything else fails --------------------
cat > "$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
[[ -n "${STUB_CALL_LOG:-}" ]] && printf '%s\n' "$*" >> "$STUB_CALL_LOG"
case "$1 $2" in
  "api user") [[ -n "${STUB_VIEWER:-}" ]] || exit 1; echo "$STUB_VIEWER" ;;
  "pr list") [[ -n "${STUB_PR_LIST:-}" ]] || exit 1; sed "s/__HEAD__/$(git rev-parse HEAD)/g" "$STUB_PR_LIST" ;;
  "issue list") [[ -n "${STUB_ISSUE_LIST:-}" ]] || exit 1; cat "$STUB_ISSUE_LIST" ;;
  "pr view") [[ -n "${STUB_PR_VIEW:-}" ]] || exit 1; cat "$STUB_PR_VIEW" ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH"
export STUB_VIEWER=me
echo '[]' > "$TMP/issues-none.json"
echo '[{"number":55}]' > "$TMP/issues-55.json"
export STUB_ISSUE_LIST="$TMP/issues-none.json"

# ---- fixture repo: feature branch fully pushed ---------------------------------------
git init -q --bare "$TMP/origin.git"
git clone -q "$TMP/origin.git" "$TMP/work" 2>/dev/null
W="$TMP/work"
git -C "$W" checkout -q -b main
echo a > "$W/a.txt"; git -C "$W" add a.txt; git -C "$W" commit -q -m base
git -C "$W" push -q -u origin main 2>/dev/null
git -C "$W" checkout -q -b feature-x
echo b > "$W/b.txt"; git -C "$W" add b.txt; git -C "$W" commit -q -m work
git -C "$W" push -q -u origin feature-x 2>/dev/null

echo '[]' > "$TMP/pr-none.json"
echo '[{"number":7,"state":"MERGED","url":"https://example.test/7","author":{"login":"me"},"mergedAt":"2026-01-01T00:00:00Z","headRefName":"feature-x","headRefOid":"__HEAD__"}]' > "$TMP/pr-merged.json"
echo '[{"number":8,"state":"OPEN","url":"https://example.test/8","author":{"login":"me"},"mergedAt":null,"headRefName":"feature-x","headRefOid":"__HEAD__"}]' > "$TMP/pr-open-mine.json"
echo '[{"number":9,"state":"OPEN","url":"https://example.test/9","author":{"login":"someone-else"},"mergedAt":null,"headRefName":"feature-x","headRefOid":"__HEAD__"}]' > "$TMP/pr-open-other.json"

echo '{}' > "$STATE"
run() { (cd "$W" && "$SCRIPT" --session "$SESSION" --repo "$REPO" --worktree "$W" "$@"); }
jqr() { jq -r "$1" <<<"$OUT"; }

# ---- 1. clean thread: merged PR, clean worktree, no state -> safe, <= 3 text lines -----
export STUB_PR_LIST="$TMP/pr-merged.json"
OUT="$(run)"; rc=$?
[[ $rc == 0 && "$(jqr .verdict)" == safe && "$(jqr .outstanding)" == 0 ]] || { echo "$OUT" >&2; fail "clean thread was not safe (rc=$rc)"; }
[[ "$(jqr '[.items[]|select(.consequence=="harmless")]|length')" -ge 1 ]] || fail "harmless items were not listed"
lines="$(run --text | wc -l | tr -d ' ')"
[[ "$lines" -le 3 ]] || fail "clean text output was $lines lines"
[[ "$(run --text | head -1)" == Safe* ]] || fail "first text line is not the verdict"
ok "merged PR + clean worktree is safe; harmless-only stays safe; clean text <= 3 lines"

# ---- 2. read-only: nothing under HOME or the repo changed ------------------------------
snap() { (cd "$TMP" && find home work -type f -not -name script-usage.log -not -path '*/.git/index.lock' -exec shasum {} + 2>/dev/null | LC_ALL=C sort; \
  ls "$TMP/origin.git/refs/heads" | LC_ALL=C sort); }
before="$(snap)"; run >/dev/null; after="$(snap)"
[[ "$before" == "$after" ]] || fail "a file changed while the inventory ran"
ok "no file changed across a run"

# ---- 3. uncommitted edit -> lost ------------------------------------------------------
echo dirty > "$W/dirty.txt"
OUT="$(run)"; rc=$?
[[ $rc == 1 && "$(jqr .verdict)" == not_yet ]] || fail "dirty worktree did not block"
[[ "$(jqr '[.items[]|select(.category=="worktrees" and .consequence=="lost")]|length')" == 1 ]] || fail "dirty worktree not tagged lost"
[[ "$(run --text | head -1)" == "Not yet: 1 outstanding."* ]] || fail "first text line is not the not-yet count"
rm -f "$W/dirty.txt"
ok "uncommitted work is lost and forces not-yet"

# ---- 4. unpushed commit -> lost ---------------------------------------------------------
echo c > "$W/c.txt"; git -C "$W" add c.txt; git -C "$W" commit -q -m local-only
OUT="$(run)"
[[ "$(jqr '[.items[]|select(.id|startswith("unpushed:"))|.consequence]|first')" == lost ]] || fail "unpushed commit not tagged lost"
git -C "$W" push -q origin feature-x 2>/dev/null
ok "unpushed commits are lost"

# ---- 5. registered background task -> keeps_running ---------------------------------------
"$ROOT/.claude/scripts/background-task-registry.sh" --repo "$REPO" --register --session "$SESSION" \
  --task-id bash-1 --type bash --name watcher >/dev/null || fail "could not register fixture task"
"$ROOT/.claude/scripts/background-task-registry.sh" --repo "$REPO" --register --session other-sess \
  --task-id bash-2 --type bash --name theirs >/dev/null || fail "could not register sibling task"
OUT="$(run)"; rc=$?
[[ $rc == 1 && "$(jqr '[.items[]|select(.category=="background_tasks" and .consequence=="keeps_running")]|length')" == 1 ]] \
  || { echo "$OUT" >&2; fail "background task not listed as keeps_running (exactly this thread's)"; }
ok "this thread's background task keeps running; a sibling session's is not counted"
"$ROOT/.claude/scripts/background-task-registry.sh" --repo "$REPO" --transition --session "$SESSION" --task-id bash-1 --status stopped >/dev/null
"$ROOT/.claude/scripts/background-task-registry.sh" --repo "$REPO" --transition --session other-sess --task-id bash-2 --status stopped >/dev/null

# ---- 6. other thread's / other author's items are excluded from the count -----------------
export STUB_PR_LIST="$TMP/pr-open-other.json"
jq -n '{active_agents:{"a-1":{id:"a-1",session_id:"other-sess",status:"spawned"},"a-2":{id:"a-2",owner_repo:"elsewhere/else",status:"spawned"}}}' > "$STATE"
OUT="$(run)"; rc=$?
[[ $rc == 0 && "$(jqr .verdict)" == safe ]] || { echo "$OUT" >&2; fail "another author's PR / another session's agents counted against this thread"; }
[[ "$(jqr '.excluded|length')" == 3 ]] || fail "excluded context missing (got $(jqr '.excluded|length'))"
ok "other author's PR and other threads' records are excluded, not counted"

# ---- 7. own open PR -> orphaned ------------------------------------------------------------
export STUB_PR_LIST="$TMP/pr-open-mine.json"
OUT="$(run)"; rc=$?
[[ $rc == 1 && "$(jqr '[.items[]|select(.category=="open_prs" and .consequence=="orphaned")]|length')" == 1 ]] || fail "own open PR not orphaned"
ok "this thread's open PR is orphaned"

# ---- 8. branch pushed without a PR -> orphaned ---------------------------------------------
export STUB_PR_LIST="$TMP/pr-none.json"
OUT="$(run)"
[[ "$(jqr '[.items[]|select(.category=="branches" and .consequence=="orphaned")]|length')" == 1 ]] || fail "PR-less branch not orphaned"
ok "pushed branch with no PR is orphaned"

# ---- 9. unreadable state is unknown, never an empty success --------------------------------
export STUB_PR_LIST="$TMP/pr-merged.json"
echo 'not json {' > "$STATE"
OUT="$(run)"; rc=$?
[[ $rc == 1 && "$(jqr .verdict)" == not_yet ]] || { echo "$OUT" >&2; fail "corrupt state did not force not-yet"; }
[[ "$(jqr .categories.subagents.status)" == unknown && "$(jqr .categories.background_tasks.status)" == unknown ]] || fail "unreadable categories not marked unknown"
rm -f "$STATE"
OUT="$(run)"
[[ "$(jqr .verdict)" == not_yet && "$(jqr .categories.subagents.status)" == unknown ]] || fail "missing state file read as empty"
echo '{}' > "$STATE"
ok "a failed state read is unknown and forces not-yet (corrupt and missing)"

# ---- 10. records that name no owner cannot be attributed -> unknown ------------------------
jq -n '{active_agents:{"a-3":{id:"a-3",status:"spawned"},"a-4":{id:"a-4",status:"done"}}}' > "$STATE"
OUT="$(run)"
[[ "$(jqr .categories.subagents.status)" == unknown && "$(jqr '.items[]|select(.category=="subagents")|.ref.keys|join(",")')" == a-3 ]] \
  || { echo "$OUT" >&2; fail "unattributable record not reported as unknown (or terminal one was)"; }
echo '{}' > "$STATE"
ok "an unowned non-terminal record is unknown; a terminal one is ignored"

# ---- 10b. an ownerless record that predates the session is excluded context (issue #2448) -----
# October record naming a merged PR; the session's transcript starts in November.
mkdir -p "$HOME/.claude/projects/proj"
printf '%s\n' '{"type":"summary"}' '{"type":"user","timestamp":"2026-11-17T09:00:00.123Z"}' > "$HOME/.claude/projects/proj/$SESSION.jsonl"
jq -n '{active_agents:{"a-old":{id:"a-old",task:"issue-873",pr:873,phase:"B",status:"spawned",launched:"2026-10-02T12:00:00Z"}},
        pipelines:{"2718":{started_at:"2026-10-05T08:00:00Z",pr:null}}}' > "$STATE"
OUT="$(run)"; rc=$?
[[ $rc == 0 && "$(jqr .verdict)" == safe ]] || { echo "$OUT" >&2; fail "an ownerless record older than the session blocked the verdict"; }
[[ "$(jqr '[.excluded[]|select(.id==".active_agents:a-old" or .id==".pipelines:2718")]|length')" == 2 ]] || { echo "$OUT" >&2; fail "predating records not listed in excluded[]"; }
grep -q 'before this session' <<<"$(jqr '.excluded[]|select(.id==".active_agents:a-old")|.reason')" || fail "excluded reason does not say why"
[[ "$(jqr .session_start.at)" == "2026-11-17T09:00:00.123Z" ]] || fail "session start not read from the transcript"
ok "an ownerless record that predates the session's first activity is excluded with a reason"

# Same record without a timestamp and without a PR: fail closed, one unknown item.
jq -n '{active_agents:{"a-old":{id:"a-old",task:"issue-873",phase:"B",status:"spawned"}}}' > "$STATE"
OUT="$(run)"; rc=$?
[[ $rc == 1 && "$(jqr .verdict)" == not_yet && "$(jqr '[.items[]|select(.consequence=="unknown")]|length')" == 1 ]] \
  || { echo "$OUT" >&2; fail "an ownerless record with no timestamp was not unknown"; }
# A record written after the session started stays unknown too.
jq -n '{active_agents:{"a-new":{id:"a-new",status:"spawned",launched:"2026-11-18T00:00:00Z"}}}' > "$STATE"
OUT="$(run)"
[[ "$(jqr .verdict)" == not_yet && "$(jqr .categories.subagents.status)" == unknown ]] || fail "a record newer than the session start was excluded"
# No session start (no transcript, no flag): the old record stays unknown.
rm -f "$HOME/.claude/projects/proj/$SESSION.jsonl"
jq -n '{active_agents:{"a-old":{id:"a-old",status:"spawned",launched:"2026-10-02T12:00:00Z"}}}' > "$STATE"
OUT="$(run)"
[[ "$(jqr .verdict)" == not_yet && "$(jqr .session_start)" == null ]] || fail "an old record was excluded with no session start"
# An explicit --session-start supplies it; an unparsable one is a usage error.
OUT="$(run --session-start 2026-11-01T00:00:00Z)"
[[ "$(jqr .verdict)" == safe ]] || { echo "$OUT" >&2; fail "--session-start was not honoured"; }
run --session-start yesterday >/dev/null 2>&1; [[ $? == 2 ]] || fail "an unparsable --session-start should exit 2"
echo '{}' > "$STATE"
ok "no timestamp, a newer record, or no session start keeps the record unknown (fail closed)"

# ---- 11. no session id and a failing GitHub read are unknown -------------------------------
OUT="$(cd "$W" && env -u CLAUDE_SESSION_ID "$SCRIPT" --repo "$REPO" --worktree "$W")"
[[ "$(jqr .categories.background_tasks.status)" == unknown && "$(jqr .verdict)" == not_yet ]] || fail "missing session id not unknown"
OUT="$(STUB_VIEWER= run)"
[[ "$(jqr .categories.open_prs.status)" == unknown ]] || fail "unresolvable viewer not unknown"
OUT="$(STUB_PR_LIST= run)"
[[ "$(jqr .categories.open_prs.status)" == unknown && "$(jqr .verdict)" == not_yet ]] || fail "failed PR read not unknown"
ok "no session id and failed GitHub reads are unknown"

# ---- 12. scratchpad files are harmless; an unreadable one is unknown -----------------------
mkdir -p "$TMP/scratch"; echo x > "$TMP/scratch/f.txt"
OUT="$(run --scratchpad "$TMP/scratch")"
[[ "$(jqr .verdict)" == safe && "$(jqr '[.items[]|select(.category=="scratchpad" and .consequence=="harmless")]|length')" == 1 ]] || fail "scratch files not harmless"
OUT="$(run --scratchpad "$TMP/missing")"
[[ "$(jqr .categories.scratchpad.status)" == unknown ]] || fail "missing scratchpad not unknown"
ok "scratch files are harmless; an unreadable scratchpad is unknown"

# ---- 13. issue-branch claim read failure is unknown ----------------------------------------
git -C "$W" checkout -q -b issue-55-thing
git -C "$W" push -q -u origin issue-55-thing 2>/dev/null
OUT="$(run)"
[[ "$(jqr .categories.claims.status)" == unknown ]] || { echo "$OUT" >&2; fail "failed claim read not unknown"; }
ok "an unreadable issue claim is unknown"

# ---- 13b. claims are enumerated by account, not only by named issues ------------------------
git -C "$W" checkout -q feature-x
OUT="$(STUB_ISSUE_LIST= run)"
[[ "$(jqr .categories.claims.status)" == unknown && "$(jqr .verdict)" == not_yet ]] || fail "failed claim enumeration read as no claims"
OUT="$(STUB_ISSUE_LIST="$TMP/issues-55.json" run)"
[[ "$(jqr .categories.claims.status)" == unknown ]] || fail "listed in-progress issue with unreadable claim not unknown"
ok "claims enumeration failure is unknown; in-progress issues are checked even without a named issue"

# ---- 13c. a PR closed without merging is not proof the work landed --------------------------
echo '[{"number":11,"state":"CLOSED","url":"https://example.test/11","author":{"login":"me"},"mergedAt":null,"headRefName":"feature-x","headRefOid":"__HEAD__"}]' > "$TMP/pr-closed.json"
OUT="$(STUB_PR_LIST="$TMP/pr-closed.json" run)"
[[ "$(jqr '[.items[]|select(.category=="open_prs" and .consequence=="orphaned")]|length')" == 1 && "$(jqr .verdict)" == not_yet ]] || fail "closed-unmerged PR treated as landed"
ok "a PR closed without merging stays outstanding"

# ---- 13d. a merged PR that does not include the current head leaves the extra commits outstanding
echo '[{"number":12,"state":"MERGED","url":"https://example.test/12","author":{"login":"me"},"mergedAt":"2026-01-01T00:00:00Z","headRefName":"feature-x","headRefOid":"0000000000000000000000000000000000000000"}]' > "$TMP/pr-merged-stale.json"
OUT="$(STUB_PR_LIST="$TMP/pr-merged-stale.json" run)"
[[ "$(jqr '[.items[]|select(.category=="branches" and .consequence=="orphaned")]|length')" == 1 && "$(jqr .verdict)" == not_yet ]] || fail "merged PR not covering HEAD treated as landed"
ok "a merged PR that does not cover the current head leaves the branch outstanding"

# ---- 13g. a closed PR whose branch head a merged PR covers is harmless ---------------------------
echo '[{"number":13,"state":"CLOSED","url":"https://example.test/13","author":{"login":"me"},"mergedAt":null,"headRefName":"feature-x","headRefOid":"__HEAD__"},{"number":14,"state":"MERGED","url":"https://example.test/14","author":{"login":"me"},"mergedAt":"2026-01-01T00:00:00Z","headRefName":"feature-x","headRefOid":"__HEAD__"}]' > "$TMP/pr-closed-then-merged.json"
OUT="$(STUB_PR_LIST="$TMP/pr-closed-then-merged.json" run)"
[[ "$(jqr .verdict)" == safe ]] || { echo "$OUT" >&2; fail "closed PR superseded by a merged one blocked the verdict"; }
ok "a closed PR superseded by a merged PR is harmless"

# ---- 13h. a finished task's worktree is still checked for unsaved work ---------------------------
git clone -q "$TMP/origin.git" "$TMP/work2" 2>/dev/null
git -C "$TMP/work2" checkout -q feature-x
echo unsaved > "$TMP/work2/unsaved.txt"
"$ROOT/.claude/scripts/background-task-registry.sh" --repo "$REPO" --register --session "$SESSION" \
  --task-id agent-done --type agent --recovery-path "$TMP/work2" >/dev/null || fail "could not register fixture agent"
"$ROOT/.claude/scripts/background-task-registry.sh" --repo "$REPO" --transition --session "$SESSION" --task-id agent-done --status done >/dev/null
OUT="$(run)"
[[ "$(jqr '[.items[]|select(.id|startswith("dirty:") and endswith("work2"))|.consequence]|first')" == lost ]] || { echo "$OUT" >&2; fail "finished task's dirty worktree not reported"; }
[[ "$(jqr '[.items[]|select(.category=="background_tasks")]|length')" == 0 ]] || fail "a finished task was listed as running"
ok "a finished task's dirty worktree is lost; the finished task itself is not keeps_running"
rm -f "$TMP/work2/unsaved.txt"

# ---- 13e. a detached checkout cannot be attributed ---------------------------------------------
git -C "$W" checkout -q --detach
OUT="$(run)"
[[ "$(jqr .categories.branches.status)" == unknown && "$(jqr .verdict)" == not_yet ]] || fail "detached HEAD not unknown"
git -C "$W" checkout -q feature-x
ok "a detached checkout is unknown"

# ---- 13f. pause markers: an active one is orphaned, a cleared one is harmless ----------------------
jq -n --arg s "$SESSION" '{execution_pauses:{($s):{active:true}}}' > "$STATE"
OUT="$(run)"
[[ "$(jqr '[.items[]|select(.category=="state_markers" and .consequence=="orphaned")]|length')" == 1 ]] || fail "active pause marker not orphaned"
jq -n --arg s "$SESSION" '{execution_pauses:{($s):{active:false}}}' > "$STATE"
OUT="$(run)"
[[ "$(jqr '[.items[]|select(.category=="state_markers" and .consequence=="harmless")]|length')" == 1 && "$(jqr .verdict)" == safe ]] || fail "cleared pause marker not harmless"
echo '{}' > "$STATE"
ok "an active pause marker is orphaned; a cleared one is harmless"

# ---- 13g. the writers keep markers under .repos[<repo>]: those must be seen too (issue #2262) ----------
jq -n --arg s "$SESSION" --arg r "$REPO" '{repos:{($r):{execution_pauses:{($s):{active:true}}, resumes:{($s):{at:"x"}}}}}' > "$STATE"
OUT="$(run)"
[[ "$(jqr '[.items[]|select(.category=="state_markers" and .consequence=="orphaned")]|length')" == 2 && "$(jqr .verdict)" == not_yet ]] \
  || { echo "$OUT" >&2; fail "repo-scoped markers were not seen"; }
jq -n --arg s "other-sess" --arg r "$REPO" '{repos:{($r):{execution_pauses:{($s):{active:true}}}}}' > "$STATE"
OUT="$(run)"
[[ "$(jqr .verdict)" == safe ]] || fail "another session's repo-scoped marker counted against this thread"
jq -n --arg s "$SESSION" --arg r "$REPO" '{execution_pauses:{($s):{active:false}}, repos:{($r):{execution_pauses:{($s):{active:true}}}}}' > "$STATE"
OUT="$(run)"
[[ "$(jqr .verdict)" == not_yet && "$(jqr '[.items[]|select(.category=="state_markers" and .consequence=="orphaned")]|length')" == 1 ]] \
  || fail "a cleared legacy marker hid an active repo-scoped one"
jq -n --arg r "$REPO" '{repos:{($r):{resumes:"oops"}}}' > "$STATE"
OUT="$(run)"
[[ "$(jqr .verdict)" == not_yet && "$(jqr '.categories.state_markers.status')" == unknown ]] || fail "a marker map of the wrong shape must be unknown, not an absent entry"
jq -n --arg r "$REPO" '{repos:{($r):{leave:"armed"}}}' > "$STATE"
OUT="$(run)"
[[ "$(jqr .verdict)" == not_yet && "$(jqr '.categories.state_markers.status')" == unknown ]] || fail "a leave marker of the wrong shape must be unknown, not an absent entry"
echo '{}' > "$STATE"
ok "repo-scoped markers are seen, another session's are not counted, a cleared legacy entry does not hide an active scoped one, a wrong-shaped map is unknown"

# ---- 13h. the default-branch exemption follows origin/HEAD, not the names main/master (issue #2271) ------
# Own clone so the earlier cases keep their meaning. The gh stub logs every call outside home/work; the
# PR list is always [] so a covered default cannot be mistaken for an inspected one.
export STUB_CALL_LOG="$TMP/gh-calls.log"
export STUB_PR_LIST="$TMP/pr-none.json"
echo '{}' > "$STATE"
git clone -q "$TMP/origin.git" "$TMP/dwork" 2>/dev/null
D="$TMP/dwork"
git -C "$D" checkout -q -B main origin/main
runD() { : > "$STUB_CALL_LOG"; (cd "$D" && "$SCRIPT" --session "$SESSION" --repo "$REPO" --worktree "$D" "$@"); }
head_called() { grep -qx "pr list .*--head $1\( .*\)\?" "$STUB_CALL_LOG"; }
nbranch() { jq -r --arg id "branch:$1" '[.items[]|select(.id==$id)]|length' <<<"$OUT"; }
set_default() { git -C "$D" symbolic-ref refs/remotes/origin/HEAD "refs/remotes/origin/$1"; }
git -C "$D" checkout -q -b release/stable main
git -C "$D" push -q origin release/stable 2>/dev/null
set_default release/stable
[[ "$(git -C "$D" symbolic-ref refs/remotes/origin/HEAD)" == refs/remotes/origin/release/stable ]] || fail "could not set origin/HEAD"

# custom, slash-bearing default: exempt from branch/PR inspection
OUT="$(runD)"; rc=$?
[[ $rc == 0 && "$(jqr '[.items[]|select(.id|startswith("clean:"))|.consequence]|first')" == harmless ]] || { echo "$OUT" >&2; fail "custom default checkout not clean/harmless"; }
[[ "$(jqr '[.items[]|select(.category=="branches")]|length')" == 0 ]] || fail "custom default produced a branch item"
head_called release/stable && fail "custom default was looked up as a PR head"
ok "a custom slash-bearing default is exempt from branch and PR inspection"

# unsaved work on the default is still reported
echo x > "$D/dirty.txt"
OUT="$(runD)"; rc=$?
[[ $rc == 1 && "$(jqr .verdict)" == not_yet && "$(jqr '[.items[]|select(.id|startswith("dirty:"))|.consequence]|first')" == lost ]] || fail "dirty custom default not lost"
rm -f "$D/dirty.txt"
echo y > "$D/y.txt"; git -C "$D" add y.txt; git -C "$D" commit -q -m local-only
OUT="$(runD)"
[[ "$(jqr '[.items[]|select(.id|startswith("unpushed:"))|.consequence]|first')" == lost ]] || fail "unpushed commit on custom default not lost"
git -C "$D" reset -q --hard origin/release/stable
ok "dirty and unpushed work on the default checkout is still lost"

# converse: a non-default branch named main is inspected
git -C "$D" checkout -q main
OUT="$(runD)"
head_called main || fail "non-default main was not looked up"
[[ "$(nbranch main)" == 1 && "$(jqr '[.items[]|select(.id=="branch:main")|.consequence]|first')" == harmless ]] || { echo "$OUT" >&2; fail "same-SHA non-default main not one harmless branch item"; }
echo z > "$D/z.txt"; git -C "$D" add z.txt; git -C "$D" commit -q -m ahead; git -C "$D" push -q origin main 2>/dev/null
OUT="$(runD)"; rc=$?
[[ $rc == 1 && "$(jqr .verdict)" == not_yet && "$(jqr '[.items[]|select(.id=="branch:main")|.consequence]|first')" == orphaned ]] || { echo "$OUT" >&2; fail "pushed-ahead non-default main not orphaned"; }
ok "a non-default branch named main is inspected (harmless at the default SHA, orphaned when ahead)"

# dangling origin/HEAD naming the checkout: no exemption, fails closed
git -C "$D" reset -q --hard origin/main 2>/dev/null; git -C "$D" push -q -f origin main 2>/dev/null
git -C "$D" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/ghost
git -C "$D" checkout -q -B ghost origin/main
OUT="$(runD)"; rc=$?
head_called ghost || fail "dangling default was exempted"
[[ $rc == 1 && "$(jqr .categories.branches.status)" == unknown && "$(jqr '[.items[]|select(.category=="branches" and .consequence=="unknown")]|length')" -ge 1 ]] \
  || { echo "$OUT" >&2; fail "dangling origin/HEAD did not fail closed to unknown"; }
ok "a dangling origin/HEAD naming the checkout gives no exemption and is unknown"

# no default evidence at all
git -C "$D" symbolic-ref --delete refs/remotes/origin/HEAD
git -C "$D" update-ref -d refs/remotes/origin/main
git -C "$D" checkout -q -B other-y origin/release/stable
OUT="$(runD)"; rc=$?
[[ $rc == 1 && "$(jqr .verdict)" == not_yet && "$(jqr '[.items[]|select(.category=="branches" and .consequence=="unknown")]|length')" -ge 1 ]] \
  || { echo "$OUT" >&2; fail "no default evidence did not give unknown"; }
ok "no resolvable default is unknown, not exempt"

# fallback: origin/HEAD absent, origin/main present -> clean main is still the default
git -C "$D" fetch -q origin 2>/dev/null
git -C "$D" update-ref refs/remotes/origin/main "$(git --git-dir="$TMP/origin.git" rev-parse main)"
git -C "$D" checkout -q -B main origin/main
OUT="$(runD)"
[[ "$(nbranch main)" == 0 ]] || fail "fallback origin/main default produced a branch item"
head_called main && fail "fallback default was looked up as a PR head"
ok "with origin/HEAD absent the origin/main fallback still exempts main"

# ambiguous: origin/HEAD absent and both origin/main and origin/master exist -> no exemption for main
git -C "$D" symbolic-ref --delete refs/remotes/origin/HEAD 2>/dev/null
git -C "$D" update-ref refs/remotes/origin/master "$(git --git-dir="$TMP/origin.git" rev-parse main)"
OUT="$(runD)"
head_called main || fail "ambiguous main/master default exempted main from PR inspection"
git -C "$D" update-ref -d refs/remotes/origin/master
ok "with both origin/main and origin/master and no origin/HEAD, main is not exempted"
unset STUB_CALL_LOG
echo '{}' > "$STATE"

# ---- 14. usage ---------------------------------------------------------------------------------
help_out="$("$SCRIPT" --help)"
grep -q 'safe-close-inventory.sh' <<<"$help_out" || fail "--help missing"
"$SCRIPT" --bogus >/dev/null 2>&1; [[ $? == 2 ]] || fail "unknown flag should exit 2"
ok "--help and usage errors"

echo "all safe-close-inventory tests passed"
