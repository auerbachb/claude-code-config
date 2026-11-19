#!/usr/bin/env bash
# Unit tests for state-owner-stamp-lint.sh (issue #2448)
# covers: .github/scripts/state-owner-stamp-lint.sh .claude/skills/subagent/SKILL.md .claude/skills/pr-monitor-and-manage/references/pmm-act.md
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
LINT="$REPO_ROOT/.github/scripts/state-owner-stamp-lint.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null

fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok   — $*"; }

fixture() { # <name> <file body>
  local d="$TMP/$1"
  mkdir -p "$d/.claude/skills/x"
  printf '%s\n' "$2" > "$d/.claude/skills/x/SKILL.md"
  git -C "$d" init -q
  git -C "$d" add -A
  printf '%s' "$d"
}

# 1. the real tree passes
bash "$LINT" >/dev/null || fail "the repository's own writers do not pass"
ok "the repository's writers all stamp session_id"

# 2. an unstamped agent write fails
d="$(fixture unstamped 'ENTRY=$(jq -n "{id:\$id, status:\"spawned\"}")
session-state.sh --set ".active_agents[\"$ID\"]=$ENTRY"')"
bash "$LINT" --root "$d" >/dev/null 2>&1; [[ $? == 1 ]] || fail "an unstamped .active_agents write passed"
ok "an unstamped .active_agents write is reported"

# 3. a session_id comment beside an unstamped write is not evidence
d="$(fixture comment '# session_id is stamped elsewhere
ENTRY=$(jq -n "{id:\$id, status:\"spawned\"}")
session-state.sh --set ".active_agents[\"$ID\"]=$ENTRY"')"
bash "$LINT" --root "$d" >/dev/null 2>&1; [[ $? == 1 ]] || fail "a comment counted as a session_id stamp"
ok "a comment mentioning session_id does not count"

# 4. a stamped entry passes (control)
d="$(fixture stamped 'ENTRY=$(jq -n --arg sid "$S" "{id:\$id, status:\"spawned\", session_id:\$sid}")
session-state.sh --set ".active_agents[\"$ID\"]=$ENTRY"')"
bash "$LINT" --root "$d" >/dev/null || fail "a stamped write was reported"
ok "a write with a session_id field passes"

# 5. a pipeline start without session_id fails; a sub-field update is not a creation
d="$(fixture pipeline 'session-state.sh --set ".repos[\"$R\"].pipelines[\"12\"].started_at=$NOW"')"
bash "$LINT" --root "$d" >/dev/null 2>&1; [[ $? == 1 ]] || fail "an unstamped pipeline start passed"
d="$(fixture update 'session-state.sh --set ".active_agents[\"$ID\"].status=\"done\""')"
bash "$LINT" --root "$d" >/dev/null || fail "a sub-field update was treated as a creation"
ok "pipeline starts are checked; sub-field updates are not"

# 6. a neighbouring record's session_id is not borrowed
d="$(fixture borrow 'A=$(jq -n --arg sid "$S" "{id:\"a\", session_id:\$sid}")
B=$(jq -n "{id:\"b\", status:\"spawned\"}")
session-state.sh --set ".active_agents[\"a\"]=$A"
session-state.sh --set ".active_agents[\"b\"]=$B"')"
out="$(bash "$LINT" --root "$d" 2>/dev/null)"; rc=$?
[[ $rc == 1 ]] || fail "an unstamped agent borrowed the session_id of a neighbouring record"
if ! grep -q 'active_agents\[\\"b\\"\]' <<<"$out" || grep -q 'active_agents\[\\"a\\"\]' <<<"$out"; then
  echo "$out" >&2; fail "the wrong write was reported"
fi
d="$(fixture borrow-pipe 'session-state.sh --set ".repos[\"$R\"].pipelines[\"12\"].started_at=$NOW" \
  --set ".repos[\"$R\"].pipelines[\"13\"].session_id=$SID"')"
bash "$LINT" --root "$d" >/dev/null 2>&1; [[ $? == 1 ]] || fail "a pipeline start borrowed another key's session_id"
d="$(fixture pipe-ok 'session-state.sh --set ".repos[\"$R\"].pipelines[\"12\"].started_at=$NOW" \
  --set ".repos[\"$R\"].pipelines[\"12\"].session_id=$SID"')"
bash "$LINT" --root "$d" >/dev/null || fail "a pipeline start with its own session_id was reported"
ok "a neighbouring record's session_id never vouches for another write"

echo "all state-owner-stamp-lint tests passed"
