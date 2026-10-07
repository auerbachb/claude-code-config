#!/usr/bin/env bash
# desk/tests/priorities-offline.test.sh — offline tests for the desk's
# priority commands (issue #1767). Needs no database: the order lives in a
# repo file written by .claude/scripts/pm-priority.sh, never in the store.
#
# Asserts:
#   routing   SKILL.md lists priorities.md in its router table and routes a
#             priority command from the reply order; longform.md and
#             discuss.md recognise one while a prompt waits or during a
#             discussion, the way they recognise `show` and `history`
#   contract  priorities.md carries the grammar (the required `#`), the repo
#             resolution, the issue check before a write, the output rule,
#             one line per helper exit code, and that only the verb, digits,
#             date word, and target reach the command
#   block     the anchored desk-priority-run block, run against the real
#             helper in a throwaway HOME and git repo under bash, /bin/bash
#             3.2, and zsh: top, park, show, drop, the exit line, an exit-2
#             refusal, and the ERROR line when the helper is not installed
set -uo pipefail

TESTS_DIR=$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/testlib.sh
. "$TESTS_DIR/lib/testlib.sh"
# shellcheck source=lib/skill-block.sh
. "$TESTS_DIR/lib/skill-block.sh"

SKILL_DIR="$HQ_T_DESK_DIR/skill"
REPO_ROOT=$(dirname "$HQ_T_DESK_DIR")
SCRIPTS="$REPO_ROOT/.claude/scripts"

for tool in jq git; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "SKIP: priorities-offline.test.sh — $tool is not installed"
    exit 0
  fi
done
if [ ! -x "$SCRIPTS/pm-priority.sh" ]; then
  echo "FAIL: $SCRIPTS/pm-priority.sh is missing or not executable"
  exit 1
fi

TMP=$(mktemp -d "${TMPDIR:-/tmp}/hq-priorities-offline.XXXXXX")
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT
TMP=$(cd -P "$TMP" && pwd)

# ------------------------------------------------------------------ routing
printf '== routing\n'
SKILL=$(cat "$SKILL_DIR/SKILL.md")
LONGFORM=$(cat "$SKILL_DIR/longform.md")
DISCUSS=$(cat "$SKILL_DIR/discuss.md")
PRIORITIES=$(cat "$SKILL_DIR/priorities.md")
check_contains "SKILL.md router lists priorities.md" "$SKILL" '| `priorities.md` | `top`, `bump`, `park`, `drop`, `priorities`'
check_contains "SKILL.md reply order routes a priority command" "$SKILL" 'as the whole message → load `priorities.md`'
check_contains "longform.md recognises a priority command while a prompt waits" "$LONGFORM" '→ `priorities.md`, then print this part'"'"'s card again'
check_contains "discuss.md recognises a priority command during a discussion" "$DISCUSS" '→ `priorities.md`, then go on discussing'

# ----------------------------------------------------------------- contract
printf '== contract\n'
while IFS= read -r needle; do
  [ -n "$needle" ] || continue
  check_contains "priorities.md: $needle" "$PRIORITIES" "$needle"
done <<'NEEDLES'
**The `#` is required** on every issue number
| `top: #a #b #c` (or `top #a #b`) |
| `park #N until <date>` |
`gh repo view <name> --json nameWithOwner --jq .nameWithOwner`
gh api "repos/<owner/name>/issues/<N>" --jq '[.state, (.pull_request != null)] | @tsv'
Check every issue before writing anything: a `top` is all or nothing.
never the rest of the operator's message
`history.md`'s output rule
| `exit=3` |
| `exit=4` |
Nothing here launches work, edits an issue, or writes to the store.
.claude/pm-priority.json
NEEDLES
check_absent "priorities.md: no human-queue.sh call (the order is not in the store)" "$PRIORITIES" '"$HQ"'

# -------------------------------------------------------------------- block
printf '== the desk-priority-run block\n'
BLOCK=$(hq_t_skill_block "$SKILL_DIR/priorities.md" desk-priority-run) || {
  bad "anchor desk-priority-run extracts"
  hq_t_finish "priorities-offline.test.sh"
  exit 1
}
ok "anchor desk-priority-run extracts"
check_contains "the block resolves the skills worktree first" "$BLOCK" '"$HOME/.claude/skills-worktree/.claude/scripts/pm-priority.sh"'

# A HOME whose skills worktree holds this checkout's scripts, and a repo.
H_OK="$TMP/home-ok"; H_NONE="$TMP/home-none"
mkdir -p "$H_OK/.claude/skills-worktree/.claude" "$H_NONE/.claude"
ln -s "$SCRIPTS" "$H_OK/.claude/skills-worktree/.claude/scripts"
REPO="$TMP/repo"; mkdir -p "$REPO"
git -C "$REPO" init -q && git -C "$REPO" remote add origin git@github.com:acme/widgets.git \
  || { bad "a throwaway repo could be created"; exit 1; }

# fill TARGET VERB — the block with its placeholders filled in.
fill() {
  printf '%s\n' "$BLOCK" | awk -v t="$1" -v v="$2" '{
    gsub(/<TARGET>/, t); gsub(/<VERB>/, v); print }'
}

SHELLS="bash"
if [ -x /bin/bash ] && [ "$(/bin/bash -c 'echo ${BASH_VERSINFO[0]}')" = "3" ]; then SHELLS="$SHELLS /bin/bash"; fi
if command -v zsh >/dev/null 2>&1; then SHELLS="$SHELLS zsh"; fi

for SH in $SHELLS; do
  rm -f "$REPO/.claude/pm-priority.json"
  run() { (cd "$REPO" && env HOME="$1" "$SH" -c "$(fill "$2" "$3")") 2>&1; }

  out=$(run "$H_OK" "" "top 12 4")
  check_contains "[$SH] top: the change line" "$out" "Order set: #12, #4"
  check_contains "[$SH] top: exit=0" "$out" "exit=0"
  check "[$SH] top: the file holds the order" "$(jq -c '.order' "$REPO/.claude/pm-priority.json")" "[12,4]"

  out=$(run "$H_OK" "--repo acme/widgets" "park 9 --until +2d")
  check_contains "[$SH] park through --repo: the return date is named" "$out" "#9 parked until"
  check_contains "[$SH] park through --repo: exit=0" "$out" "exit=0"

  out=$(run "$H_OK" "--dir '$REPO'" "show")
  check_contains "[$SH] show through --dir: the order" "$out" "Order:  #12, #4"
  check_contains "[$SH] show through --dir: the park" "$out" "Parked: #9 until"

  out=$(run "$H_OK" "" "drop 12")
  check_contains "[$SH] drop: the change line" "$out" "#12 dropped from the override"
  check "[$SH] drop: #12 left the order" "$(jq -c '.order' "$REPO/.claude/pm-priority.json")" "[4]"

  out=$(run "$H_OK" "" "park 4 --until 2020-01-01")
  check_contains "[$SH] a past park date: exit=2" "$out" "exit=2"
  check_contains "[$SH] a past park date: the helper's one line" "$out" "must be later than today"

  out=$(run "$H_NONE" "" "show")
  check_contains "[$SH] no helper installed: the ERROR line" "$out" "ERROR: pm-priority.sh not found"
  check_absent "[$SH] no helper installed: nothing ran" "$out" "exit="
done

hq_t_finish "priorities-offline.test.sh"
