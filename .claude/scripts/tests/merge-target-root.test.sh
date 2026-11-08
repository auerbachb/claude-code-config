#!/usr/bin/env bash
# catalog: tests — Exercises explicit clone binding and the real wrap/merge fences with two same-remote clones and cwd drift
set -uo pipefail
TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$TEST_DIR/../../.." && pwd)
# shellcheck source=lib/skill-bash.sh
source "$TEST_DIR/lib/skill-bash.sh"
TMP=$(mktemp -d)
TMP=$(cd "$TMP" && pwd -P)
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"
mkdir -p "$HOME" "$TMP/bin"
REAL_GIT=$(command -v git)
export REAL_GIT
A="$TMP/Clone A"; B="$TMP/Clone B"
URL=https://github.com/fixture/project/pull/17
REMOTE=https://github.com/fixture/project.git
for dir in "$A" "$B"; do
  git init -q "$dir" || exit 1
  git -C "$dir" remote add origin "$REMOTE" || exit 1
done
git -C "$A" -c user.name=Fixture -c user.email=fixture@example.invalid commit -qm init --allow-empty || exit 1
LINKED="$TMP/Linked worktree"
git -C "$A" worktree add -qb fixture-linked "$LINKED" || exit 1
HELPER="$ROOT/.claude/scripts/merge-target-root.sh"
PASS=0; FAIL=0
check() {
  if [[ "$2" == "$3" ]]; then PASS=$((PASS + 1)); echo "ok — $1"
  else FAIL=$((FAIL + 1)); echo "FAIL — $1 (expected '$2', actual '$3')"; fi
}
check_fail() {
  local rc=0 out
  out=$("$HELPER" "$@" 2>/dev/null) || rc=$?
  check 'invalid binding has no authority' false "$(if [[ "$rc" -eq 0 ]]; then echo true; else echo false; fi)"
  check 'invalid binding prints no root' '' "$out"
}
cd "$B" || exit 1
OUT=$("$HELPER" --repo-path "$A" --pr-url "$URL")
check 'clone A remains selected from clone B' "$A" "$OUT"
check 'linked worktree resolves to its physical main clone' "$A" "$("$HELPER" --repo-path "$LINKED" --pr-url "$URL")"
ln -s "$A" "$TMP/alias"
check 'symlink input becomes physical root' "$A" "$("$HELPER" --repo-path "$TMP/alias" --pr-url "$URL")"
for remote in git@github.com:Fixture/Project.git ssh://git@github.com/fixture/project.git https://github.com/fixture/project.git/; do
  git -C "$A" remote set-url origin "$remote"
  check 'normal remote spellings identify the same repository' "$A" "$("$HELPER" --repo-path "$A" --pr-url "$URL")"
done
git -C "$A" remote set-url origin "$REMOTE"
check_fail --repo-path '' --pr-url "$URL"
check_fail --repo-path . --pr-url "$URL"
check_fail --repo-path "$TMP/missing" --pr-url "$URL"
check_fail --repo-path "$TMP" --pr-url "$URL"
check_fail --repo-path "$A" --pr-url ''
check_fail --repo-path "$A" --pr-url https://github.com/fixture/other/pull/17
check_fail --repo-path "$A" --pr-url https://other.example/fixture/project/pull/17
check_fail --repo-path "$A" --pr-url https://github.com/fixture/project/pull/0

# Missing support and a hung identity read fail closed before any mutation.
mkdir -p "$TMP/incomplete" "$TMP/stalled"
cp "$HELPER" "$TMP/incomplete/merge-target-root.sh"
RC=0
OUT=$("$TMP/incomplete/merge-target-root.sh" --repo-path "$A" --pr-url "$URL" 2>/dev/null) || RC=$?
check 'missing required helpers return unknown' 4 "$RC"
check 'missing helpers supply no root' '' "$OUT"
cat > "$TMP/stalled/git" <<'STALLED'
#!/usr/bin/env bash
case " $* " in *' remote get-url origin '*) exec sleep 30 ;; esac
exec "$REAL_GIT" "$@"
STALLED
chmod +x "$TMP/stalled/git"
START=$(date +%s); RC=0
OUT=$(PATH="$TMP/stalled:$PATH" "$HELPER" --repo-path "$A" --pr-url "$URL" 2>/dev/null) || RC=$?
ELAPSED=$(( $(date +%s) - START ))
check 'stalled identity read returns timeout' 3 "$RC"
check 'stalled identity read supplies no root' '' "$OUT"
if [[ "$ELAPSED" -le 15 ]]; then check 'identity read stays bounded' yes yes; else check 'identity read stays bounded' '<=15s' "$ELAPSED"; fi

WRAP_DOC="$ROOT/.claude/skills/wrap/SKILL.md"
MERGE_DOC="$ROOT/.claude/skills/merge/SKILL.md"
WRAP_BIND=$(extract_skill_bash "$WRAP_DOC" wrap-merge-root-binding) || exit 1
MERGE_BIND=$(extract_skill_bash "$MERGE_DOC" merge-merge-root-binding) || exit 1
WRAP_SYNC=$(extract_skill_bash "$WRAP_DOC" wrap-bound-main-sync) || exit 1
MERGE_SYNC=$(extract_skill_bash "$MERGE_DOC" merge-bound-main-sync) || exit 1
MERGE_CLEANUP=$(extract_skill_bash "$MERGE_DOC" merge-bound-branch-cleanup) || exit 1
CALLS="$TMP/calls"
export CALLS
cat > "$TMP/bin/guard" <<'MOCK'
#!/usr/bin/env bash
printf 'guard' >> "$CALLS"; for arg do printf '|%s' "$arg" >> "$CALLS"; done; printf '\n' >> "$CALLS"
exit 0
MOCK
cat > "$TMP/bin/sync" <<'MOCK'
#!/usr/bin/env bash
printf 'sync' >> "$CALLS"; for arg do printf '|%s' "$arg" >> "$CALLS"; done; printf '\n' >> "$CALLS"
if [[ $# -eq 0 ]]; then "$REAL_GIT" rev-parse --show-toplevel > "$CALLS.effective-root"; fi
echo 'up to date (fixture)' 
exit 0
MOCK
cat > "$TMP/bin/gh" <<'MOCK'
#!/usr/bin/env bash
printf 'gh' >> "$CALLS"; for arg do printf '|%s' "$arg" >> "$CALLS"; done; printf '\n' >> "$CALLS"
case "${MOCK_PR_META:-valid}" in
  open) printf '%s\n' '{"state":"OPEN","headRefName":"fixture-feature","baseRefName":"main"}' ;;
  malformed) printf '%s\n' '{"state":"MERGED","headRefName":null,"baseRefName":"main"}' ;;
  *) printf '%s\n' '{"state":"MERGED","headRefName":"fixture-feature","baseRefName":"main"}' ;;
esac
MOCK
cat > "$TMP/bin/git" <<'MOCK'
#!/usr/bin/env bash
if [[ "${MOCK_CHECKOUT_FAIL:-0}" == 1 && "$*" == 'branch --show-current' ]]; then
  echo fixture-feature; exit 0
fi
case " $* " in
  *' branch -D '*|*' checkout '*|*' push '*)
    printf 'mutation' >> "$CALLS"; for arg do printf '|%s' "$arg" >> "$CALLS"; done; printf '\n' >> "$CALLS"
    if [[ "${MOCK_CHECKOUT_FAIL:-0}" == 1 && "$1" == checkout ]]; then exit 1; fi
    exit 0 ;;
esac
exec "$REAL_GIT" "$@"
MOCK
chmod +x "$TMP/bin/guard" "$TMP/bin/sync" "$TMP/bin/gh" "$TMP/bin/git"
export PATH="$TMP/bin:$PATH"
export MERGE_TARGET_ROOT_SH="$HELPER" DIRTY_MAIN_GUARD_SH="$TMP/bin/guard" MAIN_SYNC_SH="$TMP/bin/sync"
export WRAP_VERBOSE=0 WRAP_SOURCE_PATH="$A" MERGE_SOURCE_PATH="$A" WRAP_PR_URL="$URL" MERGE_PR_URL="$URL"
# Bind before drift, carry the exact values to the later extracted fence.
export WRAP_BOUND_ROOT="$A" MERGE_BOUND_ROOT="$A" WRAP_BOUND_PR_URL="$URL" MERGE_BOUND_PR_URL="$URL"
for SITE in wrap merge; do
  if [[ "$SITE" == wrap ]]; then BIND="$WRAP_BIND"; SYNC="$WRAP_SYNC"; else BIND="$MERGE_BIND"; SYNC="$MERGE_SYNC"; fi
  if [[ "$SITE" == wrap ]]; then BOUND_REPORT="echo \"BOUND=\$WRAP_BOUND_ROOT\""; else BOUND_REPORT="echo \"BOUND=\$MERGE_BOUND_ROOT\""; fi
  OUT=$(bash -c "$BIND"$'\n'"$BOUND_REPORT")
  check "$SITE: actual early fence binds A from absolute context" "BOUND=$A" "$OUT"
  OUT=$(WRAP_SOURCE_PATH='' MERGE_SOURCE_PATH='' bash -c "$BIND"$'\n'"$BOUND_REPORT")
  check "$SITE: early missing context does not inherit old authority" 'BOUND=' "$OUT"
  : > "$CALLS"
  OUT=$(bash -c "$SYNC"$'\n''echo "STATUS=$MAIN_SYNC_STATUS"' 2>&1)
  if [[ "$SITE" == wrap ]]; then
    EXPECTED=$(printf 'guard|--check|--repo|%s\nsync|--reset|--repo|%s' "$A" "$A")
  else EXPECTED="sync|--repo|$A"; fi
  check "$SITE: actual late fence targets only A despite cwd B" "$EXPECTED" "$(cat "$CALLS")"
  for BAD in empty missing wrong-repo missing-helper; do
    : > "$CALLS"
    case "$BAD" in
      empty) BAD_PATH='' ;;
      missing) BAD_PATH="$TMP/removed" ;;
      wrong-repo)
        BAD_PATH="$A"; "$REAL_GIT" -C "$A" remote set-url origin https://github.com/fixture/other.git ;;
      missing-helper) BAD_PATH="$A" ;;
    esac
    if [[ "$BAD" == missing-helper ]]; then BAD_HELPER="$TMP/unavailable-helper"; else BAD_HELPER="$HELPER"; fi
    OUT=$(WRAP_BOUND_ROOT="$BAD_PATH" MERGE_BOUND_ROOT="$BAD_PATH" MERGE_TARGET_ROOT_SH="$BAD_HELPER" bash -c "$SYNC"$'\n''echo "STATUS=$MAIN_SYNC_STATUS"' 2>&1)
    check "$SITE $BAD: neither guard nor sync can mutate B" '' "$(cat "$CALLS")"
    case "$OUT" in *'failed: bound clone unavailable'*) check "$SITE $BAD: failure reported" yes yes ;; *) check "$SITE $BAD: failure reported" yes "$OUT" ;; esac
    "$REAL_GIT" -C "$A" remote set-url origin "$REMOTE"
  done
done
: > "$CALLS"
OUT=$(bash -c "$MERGE_CLEANUP" 2>&1)
check 'branch cleanup skips cwd B before any PR/Git mutation' '' "$(cat "$CALLS")"
cd "$A" || exit 1
: > "$CALLS"
OUT=$(bash -c "$MERGE_CLEANUP" 2>&1)
EXPECTED=$(printf 'gh|pr|view|%s|--json|state,headRefName,baseRefName\nmutation|branch|-D|--|fixture-feature\nmutation|push|origin|--delete|fixture-feature' "$URL")
check 'branch cleanup in A uses the exact bound PR URL and branch metadata' "$EXPECTED" "$(cat "$CALLS")"

for META in open malformed; do
  : > "$CALLS"
  OUT=$(MOCK_PR_META="$META" bash -c "$MERGE_CLEANUP" 2>&1)
  check "$META branch metadata: no Git cleanup" "gh|pr|view|$URL|--json|state,headRefName,baseRefName" "$(cat "$CALLS")"
done
: > "$CALLS"
OUT=$(MOCK_CHECKOUT_FAIL=1 bash -c "$MERGE_CLEANUP" 2>&1)
check 'checkout failure prevents branch/remote deletion' "$(printf 'gh|pr|view|%s|--json|state,headRefName,baseRefName\nmutation|checkout|main|--' "$URL")" "$(cat "$CALLS")"

# Execute both published old fences, not a reimplementation of their discovery.
cd "$B" || exit 1
export REPO_ROOT_SH="$ROOT/.claude/scripts/repo-root.sh"
OLD_WRAP=$(extract_skill_bash "$TEST_DIR/fixtures/merge-target-pre1646.md" old-wrap-main-sync) || exit 1
OLD_MERGE=$(extract_skill_bash "$TEST_DIR/fixtures/merge-target-pre1646.md" old-merge-main-sync) || exit 1
: > "$CALLS"
OUT=$(bash -c "$OLD_WRAP" 2>&1)
check 'negative published wrap invokes mutations on B' "$(printf 'guard|--check|--repo|%s\nsync|--reset|--repo|%s' "$B" "$B")" "$(cat "$CALLS")"
: > "$CALLS"
OUT=$(bash -c "$OLD_MERGE" 2>&1)
check 'negative published merge calls sync with no explicit clone' sync "$(cat "$CALLS")"
check 'negative published merge defaults to wrong clone B' "$B" "$(cat "$CALLS.effective-root")"

# Independently exercise the real main-sync CLI against two LOCAL clones.
# No remote service is contacted: the fetch/pull target is a private bare repo.
BARE="$TMP/local-origin.git"; SEED="$TMP/seed"; PULL_A="$TMP/pull A"; PULL_B="$TMP/pull B"
"$REAL_GIT" init --bare -q --initial-branch=main "$BARE" || exit 1
"$REAL_GIT" init -q --initial-branch=main "$SEED" || exit 1
"$REAL_GIT" -C "$SEED" -c user.name=Fixture -c user.email=fixture@example.invalid commit -qm first --allow-empty || exit 1
"$REAL_GIT" -C "$SEED" remote add origin "$BARE"
"$REAL_GIT" -C "$SEED" push -q origin main || exit 1
"$REAL_GIT" clone -q "$BARE" "$PULL_A" || exit 1
"$REAL_GIT" clone -q "$BARE" "$PULL_B" || exit 1
OLD_HEAD=$("$REAL_GIT" -C "$PULL_B" rev-parse HEAD)
"$REAL_GIT" -C "$SEED" -c user.name=Fixture -c user.email=fixture@example.invalid commit -qm second --allow-empty || exit 1
"$REAL_GIT" -C "$SEED" push -q origin main || exit 1
NEW_HEAD=$("$REAL_GIT" -C "$SEED" rev-parse HEAD)
cd "$PULL_B" || exit 1
RC=0
OUT=$("$ROOT/.claude/scripts/main-sync.sh" --repo "$PULL_A" 2>&1) || RC=$?
check 'real explicit main-sync succeeds from a second clone' 0 "$RC"
check 'real explicit main-sync updates A' "$NEW_HEAD" "$("$REAL_GIT" -C "$PULL_A" rev-parse HEAD)"
check 'real explicit main-sync leaves B unchanged' "$OLD_HEAD" "$("$REAL_GIT" -C "$PULL_B" rev-parse HEAD)"

printf 'Passed: %s  Failed: %s\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
