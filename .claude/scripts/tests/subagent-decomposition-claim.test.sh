#!/usr/bin/env bash
# catalog: tests — Check inherited parent ownership in the actual decomposition gate without writing GitHub state
set -uo pipefail

ROOT=$(git rev-parse --show-toplevel) || exit 1
# shellcheck source=lib/skill-bash.sh
source "$ROOT/.claude/scripts/tests/lib/skill-bash.sh"
GATE=$(extract_skill_bash "$ROOT/.claude/skills/subagent/SKILL.md" subagent-decomposition-parent-claim) || exit 1
TEST_DIR=$(mktemp -d) || exit 1
trap 'rm -rf "$TEST_DIR"' EXIT
mkdir -p "$TEST_DIR/bin" "$TEST_DIR/profile/.claude" "$TEST_DIR/second-checkout"
git -C "$TEST_DIR/second-checkout" init -q || exit 1
export PARENT_TEST_DIR="$TEST_DIR"
jq -n --arg at "$(date -u +%FT%TZ)" \
  '[{id:12,created_at:$at,user:{login:"alice"},body:"<!-- claude-claim: {\"holder\":\"verified-original\",\"login\":\"alice\"} -->"}]' \
  > "$TEST_DIR/comments.json" || exit 1

cat > "$TEST_DIR/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
case "$*" in
  'api user --jq .login') printf 'alice\n' ;;
  'api repos/{owner}/{repo}/issues/873')
    if [[ "$PARENT_TEST_MODE" == empty ]]; then
      printf '{"number":873,"state":"open","labels":[],"assignees":[]}\n'
    else
      printf '{"number":873,"state":"open","labels":[{"name":"in-progress"}],"assignees":[{"login":"alice"}]}\n'
    fi ;;
  'api --paginate repos/{owner}/{repo}/issues/873/comments?per_page=100')
    case "$PARENT_TEST_MODE" in
      empty) printf '[]\n' ;;
      read_error) printf 'fixture: comment read failed\n' >&2; exit 1 ;;
      *) cat "$PARENT_TEST_DIR/comments.json" ;;
    esac ;;
  'api --paginate repos/{owner}/{repo}/issues/873/timeline?per_page=100') printf '[]\n' ;;
  *) printf '%s\n' "$*" >> "$PARENT_TEST_DIR/unexpected"; exit 99 ;;
esac
STUB
chmod +x "$TEST_DIR/bin/gh"

fail=0
run_case() {
  local title="$1" mode="$2" number="$3" holder="$4" expected="$5" rc=0 out
  out=$(
    cd "$TEST_DIR/second-checkout" || exit 1
    unset CLAUDE_CLAIM_HOLDER CLAUDE_SESSION_ID INHERITED_PARENT_NUMBER INHERITED_PARENT_HOLDER
    if [[ "$number" != - ]]; then export INHERITED_PARENT_NUMBER="$number"; fi
    if [[ "$holder" != - ]]; then export INHERITED_PARENT_HOLDER="$holder"; fi
    PARENT=873 ISSUE_CLAIM="$ROOT/.claude/scripts/issue-claim.sh" PARENT_TEST_MODE="$mode" \
      HOME="$TEST_DIR/profile" PATH="$TEST_DIR/bin:$PATH" \
      "$BASH" -u -c "$GATE"$'\n''printf "FILING_ALLOWED\n"' 2>&1
  ) || rc=$?
  if [[ "$rc" == "$expected" ]] &&
     { [[ "$rc" == 0 && "$out" == FILING_ALLOWED ]] ||
       [[ "$rc" != 0 && "$out" != *FILING_ALLOWED* ]]; }; then
    printf 'ok — %s\n' "$title"
  else
    printf 'FAIL — %s (rc=%s, output=%s)\n' "$title" "$rc" "$out"
    fail=1
  fi
}

run_case 'inherited holder from the original checkout verifies' claimed 873 verified-original 0
run_case 'a changed checkout cannot pass on the implicit holder' claimed - - 4
run_case 'a foreign inherited holder stops' claimed 873 foreign-holder 4
run_case 'a released inherited claim stops' empty 873 verified-original 5
run_case 'an ordinary unclaimed parent stays eligible' empty - - 0
run_case 'a holder for another issue stops' claimed 999 verified-original 5
run_case 'an incomplete inherited pair stops' claimed 873 '' 5
run_case 'an unreadable ownership check stops' read_error 873 verified-original 4

if [[ -s "$TEST_DIR/unexpected" ]]; then
  printf 'FAIL — fixture received an unexpected or write command:\n' >&2
  cat "$TEST_DIR/unexpected" >&2
  fail=1
fi
[[ "$fail" -eq 0 ]]
