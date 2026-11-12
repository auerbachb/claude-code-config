#!/usr/bin/env bash
# catalog: tests — Verifies PM resume handoff isolation for overlapping PR numbers.
# covers: .claude/skills/pm/modules/resume/load.md .claude/scripts/session-state.sh
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)
source "$root/.claude/scripts/tests/lib/skill-bash.sh"
block=$(extract_skill_bash "$root/.claude/skills/pm/modules/resume/load.md" pm-resume-scoped-handoffs)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/pm-resume-handoffs.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
export HOME="$tmp"
mkdir -p "$HOME/.claude/handoffs/first/repo" "$HOME/.claude/handoffs/second/repo"
for order in first second; do
  if [[ "$order" == first ]]; then other=second; else other=first; fi
  jq -nc --arg a "$order/repo" --arg b "$other/repo" '{
    repos:{($a):{prs:{"42":{owner_repo:$a}}},($b):{prs:{"42":{owner_repo:$b}}}}
  }' > "$HOME/.claude/session-state.json"
  for repo in first second; do
    printf '{"owner_repo":"%s/repo","pr_number":42,"needs":"%s-only"}\n' "$repo" "$repo" \
      > "$HOME/.claude/handoffs/$repo/repo/pr-42-handoff.json"
  done
  for repo in first second; do
    key="$repo/repo"
    view=$("$root/.claude/scripts/session-state.sh" --repo "$key" --session-view)
    out=$(REPO_KEY="$key" SESSION_VIEW="$view" "$BASH" -u -c "$block")
    grep -Fq "\"needs\":\"$repo-only\"" <<< "$out"
    [[ $(printf '%s\n' "$out" | wc -l | tr -d ' ') == 2 ]]
  done
  key=second/repo
  view=$("$root/.claude/scripts/session-state.sh" --repo "$key" --session-view)
  mv "$HOME/.claude/handoffs/second/repo/pr-42-handoff.json" "$HOME/second.saved"
  flat="$HOME/.claude/handoffs/pr-42-handoff.json"
  printf '%s\n' '{"owner_repo":"first/repo","needs":"wrong"}' > "$flat"
  [[ $(REPO_KEY="$key" SESSION_VIEW="$view" "$BASH" -u -c "$block") == NO_HANDOFF_FILES ]]
  printf '%s\n' '{"needs":"unknown"}' > "$flat"
  [[ $(REPO_KEY="$key" SESSION_VIEW="$view" "$BASH" -u -c "$block") == NO_HANDOFF_FILES ]]
  printf '%s\n' '{"owner_repo":"second/repo","needs":"legacy"}' > "$flat"
  out=$(REPO_KEY="$key" SESSION_VIEW="$view" "$BASH" -u -c "$block")
  grep -Fq '"needs":"legacy"' <<< "$out"
  scoped="$HOME/.claude/handoffs/second/repo/pr-42-handoff.json"
  printf '%s\n' '{"needs":"older scoped"}' > "$scoped"
  out=$(REPO_KEY="$key" SESSION_VIEW="$view" "$BASH" -u -c "$block")
  grep -Fq '"needs":"older scoped"' <<< "$out"
  printf '%s\n' '{"owner_repo":"second/repo","pr_number":null}' > "$scoped"
  [[ $(REPO_KEY="$key" SESSION_VIEW="$view" "$BASH" -u -c "$block") == NO_HANDOFF_FILES ]] || { printf '%s\n' 'explicit null PR identity was accepted' >&2; exit 1; }
  printf '%s\n' '{"owner_repo":"second/repo","pr_number":43}' > "$scoped"
  [[ $(REPO_KEY="$key" SESSION_VIEW="$view" "$BASH" -u -c "$block") == NO_HANDOFF_FILES ]]
  printf '%s\n' '{"owner_repo":"first/repo","pr_number":42}' > "$scoped"
  [[ $(REPO_KEY="$key" SESSION_VIEW="$view" "$BASH" -u -c "$block") == NO_HANDOFF_FILES ]]
  rm "$scoped"
  printf '%s\n' '{"needs":"foreign linked"}' > "$HOME/unknown-scope"
  ln -s "$HOME/unknown-scope" "$scoped"
  [[ $(REPO_KEY="$key" SESSION_VIEW="$view" "$BASH" -u -c "$block") == NO_HANDOFF_FILES ]]
  rm "$scoped"
  mv "$HOME/second.saved" "$scoped"
  foreign=$(jq -c '.repo = "first/repo"' <<< "$view")
  [[ $(REPO_KEY="$key" SESSION_VIEW="$foreign" "$BASH" -u -c "$block") == NO_HANDOFF_FILES ]]
  wrong_type=$(jq -c '.prs = [null,{},{}]' <<< "$view")
  [[ $(REPO_KEY="$key" SESSION_VIEW="$wrong_type" "$BASH" -u -c "$block") == NO_HANDOFF_FILES ]]
  split_key=$(jq -c '.prs = {"bad\n42": {}}' <<< "$view")
  [[ $(REPO_KEY="$key" SESSION_VIEW="$split_key" "$BASH" -u -c "$block") == NO_HANDOFF_FILES ]]
  dot_repo='second/.github'
  mkdir -p "$HOME/.claude/handoffs/$dot_repo"
  printf '%s\n' '{"needs":"dot repository"}' > "$HOME/.claude/handoffs/$dot_repo/pr-42-handoff.json"
  dot_view=$(jq -c --arg repo "$dot_repo" '.repo = $repo' <<< "$view")
  out=$(REPO_KEY="$dot_repo" SESSION_VIEW="$dot_view" "$BASH" -u -c "$block")
  grep -Fq '"needs":"dot repository"' <<< "$out"
  store="$HOME/.claude/handoffs"
  linked_store="$HOME/linked-handoffs"
  mv "$store" "$linked_store"
  ln -s "$linked_store" "$store"
  printf '%s\n' '{"needs":"linked store without owner"}' > "$scoped"
  [[ $(REPO_KEY="$key" SESSION_VIEW="$view" "$BASH" -u -c "$block") == NO_HANDOFF_FILES ]] || { printf '%s\n' 'ownerless linked-store payload was accepted' >&2; exit 1; }
  printf '%s\n' '{"owner_repo":"second/repo","pr_number":42,"needs":"verified linked store"}' > "$scoped"
  out=$(REPO_KEY="$key" SESSION_VIEW="$view" "$BASH" -u -c "$block")
  grep -Fq '"needs":"verified linked store"' <<< "$out"
  rm "$store"
  mv "$linked_store" "$store"
  printf '%s\n' "$order first: collisions, valid legacy, linked scope, and invalid payload/view verified"
done
