#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
HOOK="$ROOT/.claude/hooks/ai-account-session-start.sh"
fixture_home="$(mktemp -d)"; readonly fixture_home
HOME="$fixture_home"; export HOME
# Remove only this test's direct temp child; preserve any protected environment fixture.
cleanup_fixture() {
  python3 - "$fixture_home" <<'CLEANUP'
import os,pathlib,shutil,sys,tempfile
root=pathlib.Path(sys.argv[1]); base=pathlib.Path(tempfile.gettempdir()).resolve()
if root.parent.resolve()==base and root.name.startswith('tmp.') and not root.is_symlink():
 protected=any(name.lower().startswith('.env') for _,_,files in os.walk(root,followlinks=False) for name in files)
 if not protected: shutil.rmtree(root,ignore_errors=True)
CLEANUP
}
trap cleanup_fixture EXIT
export AI_ACCOUNT_LEDGER="$HOME/.claude/ai-account-ledger.jsonl"
mkdir -p "$HOME/.claude" "$HOME/personal/claude" "$HOME/work/claude" "$HOME/unknown" "$HOME/codex"
export AI_QUOTAS_CONFIG="$HOME/.claude/ai-quotas.json"
jq -n --arg a "$HOME/personal/claude" --arg b "$HOME/work/claude" --arg c "$HOME/codex" '{schema_version:"1.0",accounts:[{provider:"claude",label:"work",profile_dir:$a},{provider:"claude",label:"personal",profile_dir:$b},{provider:"codex",label:"codex-work",profile_dir:$c}]}' > "$AI_QUOTAS_CONFIG"
for repo in repo-a repo-b; do git init -q "$HOME/$repo"; git -C "$HOME/$repo" checkout -qb issue-1885-test; git -C "$HOME/$repo" -c user.name=Test -c user.email=test@example.test commit -qm init --allow-empty; done
payload() { jq -cn --arg cwd "$1" --arg source "${2:-startup}" '{session_id:"test",cwd:$cwd,source:$source}'; }
printf '%s\n' '{"oauthAccount":{"emailAddress":"evidence@example.test"}}' > "$HOME/personal/claude/.claude.json"
# Exercise the real generated launchers against a metadata-only provider stub.
mkdir -p "$HOME/bin"
export ACCOUNT_TEST_HOOK="$HOOK"
cat > "$HOME/bin/claude" <<'PROVIDER'
#!/bin/bash
exec "$ACCOUNT_TEST_HOOK" "$@"
PROVIDER
chmod +x "$HOME/bin/claude"
export PATH="$HOME/bin:$PATH" AI_QUOTAS_PLATFORM=Linux
"$ROOT/.claude/scripts/ai-quotas-setup.sh" launchers >/dev/null
launchers="$HOME/.claude/ai-quotas/launchers.zsh"
for pair in 'work repo-a' 'personal repo-b'; do
  read -r label repo <<< "$pair"
  out=$(payload "$HOME/$repo" | bash -c 'source "$1"; "$2"' _ "$launchers" "claude-$label")
  [ "$out" = '{}' ]
done
jq -se 'length==2 and .[0].label=="work" and .[1].label=="personal" and .[0].issue=="1885" and .[0].account_email==null' "$AI_ACCOUNT_LEDGER" >/dev/null
payload "$HOME" | CLAUDE_CONFIG_DIR="$HOME/unknown" "$HOOK" >/dev/null
payload "$HOME" | env -u CLAUDE_CONFIG_DIR "$HOOK" >/dev/null
jq -se '.[-2].label=="unknown" and .[-1].label=="unknown" and .[-1].repo==null' "$AI_ACCOUNT_LEDGER" >/dev/null
before=$(wc -l < "$AI_ACCOUNT_LEDGER")
for source in clear compact; do payload "$HOME" "$source" | "$HOOK" >/dev/null; done
[ "$(wc -l < "$AI_ACCOUNT_LEDGER")" = "$before" ]
payload "$HOME/repo-a" | "$HOOK" --provider codex --codex-home "$HOME/codex"
jq -e '.label=="codex-work"' < <(tail -1 "$AI_ACCOUNT_LEDGER") >/dev/null
jq -cn --arg path "$HOME/codex/sessions/2026/rollout.jsonl" '{transcript_path:$path}' | env -u CODEX_HOME "$HOOK" --provider codex
jq -e '.label=="codex-work"' < <(tail -1 "$AI_ACCOUNT_LEDGER") >/dev/null
# A home containing session-container names must retain its full declared prefix.
for pair in 'sessions nested/archived_sessions' 'archived_sessions nested/sessions'; do
  read -r outer inner <<< "$pair"
  nested="$HOME/$outer/$inner/profile"
  jq --arg path "$nested" '.accounts += [{provider:"codex",label:"nested-codex",profile_dir:$path}]' "$AI_QUOTAS_CONFIG" > "$HOME/nested-registry.json"
  for container in sessions archived_sessions; do
    jq -cn --arg path "$nested/$container/2026/11/05/rollout.jsonl" '{transcript_path:$path}' | AI_QUOTAS_CONFIG="$HOME/nested-registry.json" env -u CODEX_HOME "$HOOK" --provider codex
    jq -e --arg path "$nested" '.label=="nested-codex" and .profile_dir==$path' < <(tail -1 "$AI_ACCOUNT_LEDGER") >/dev/null
  done
done
# Transcript fallback must never select another registered spelling after stripping controls.
control_home="$HOME/"$'line\nwith\ttab\rand\037separator\\literal\n'
stripped_home=$(jq -nr --arg path "$control_home" '$path|gsub("[\u001f\t\r\n]";"")')
jq --arg intended "$control_home" --arg other "$stripped_home" '.accounts += [{provider:"codex",label:"intended-control",profile_dir:$intended},{provider:"codex",label:"wrong-stripped",profile_dir:$other}]' "$AI_QUOTAS_CONFIG" > "$HOME/transcript-control-registry.json"
for container in sessions archived_sessions; do
  jq -cn --arg path "$control_home/$container/2026/rollout.jsonl" '{transcript_path:$path}' | AI_QUOTAS_CONFIG="$HOME/transcript-control-registry.json" env -u CODEX_HOME "$HOOK" --provider codex
  jq -e --arg path "$control_home" '.label=="intended-control" and .profile_dir==$path' < <(tail -1 "$AI_ACCOUNT_LEDGER") >/dev/null
done
before=$(wc -l < "$AI_ACCOUNT_LEDGER")
printf '%s\n' '{"transcript_path":"invalid\u0000path/sessions/rollout.jsonl"}' | "$HOOK" --provider codex
[ "$(wc -l < "$AI_ACCOUNT_LEDGER")" = "$before" ]
# Repository lookup also preserves filesystem spelling instead of retargeting a stripped path.
exact_cwd="$HOME/"$'project\nwith\ttab\rand\037separator\\literal\n'
stripped_cwd=$(jq -nr --arg path "$exact_cwd" '$path|gsub("[\u001f\t\r\n]";"")')
for path in "$exact_cwd" "$stripped_cwd"; do
  git init -q "$path"
  git -C "$path" checkout -qb issue-1885-control-cwd
  slug=Wrong; [ "$path" != "$exact_cwd" ] || slug=Intended
  git -C "$path" remote add origin "https://github.com/Example/$slug.git"
done
payload "$exact_cwd" | CLAUDE_CONFIG_DIR="$HOME/personal/claude" "$HOOK" >/dev/null
jq -e '.repo==null and .branch==null and .label=="work"' < <(tail -1 "$AI_ACCOUNT_LEDGER") >/dev/null
# Each escaped control followed by an octal digit must round-trip without consuming it.
for suffix in 0 1 2 3 4 5 6 7; do
  octal_home="$HOME/"$'field\037'"$suffix"$'nl\n'"$suffix"$'tab\t'"$suffix"$'cr\r'"$suffix"$'literal\\0375\\00375\\n5\\x1f5\\c\n'
  jq -n --arg path "$octal_home" '{accounts:[{provider:"codex",label:"octal-control",profile_dir:$path}]}' > "$HOME/octal-registry.json"
  jq -cn --arg path "$octal_home/sessions/2026/rollout.jsonl" '{transcript_path:$path}' | AI_QUOTAS_CONFIG="$HOME/octal-registry.json" env -u CODEX_HOME "$HOOK" --provider codex
  jq -e --arg path "$octal_home" '.label=="octal-control" and .profile_dir==$path' < <(tail -1 "$AI_ACCOUNT_LEDGER") >/dev/null
done
# Malformed entries cannot disable capture; only valid exact matches count.
for shape in invalid mixed duplicate container; do
  jq --arg shape "$shape" 'if $shape=="invalid" then .accounts=["bad",17,null,[],{}]
    elif $shape=="mixed" then .accounts=["bad",17,null,[],{},.accounts[0]]
    elif $shape=="duplicate" then .accounts=["bad",.accounts[0],.accounts[0]]
    else .accounts={bad:.accounts[0]} end' "$AI_QUOTAS_CONFIG" > "$HOME/malformed-entry-registry.json"
  expected=unknown; [ "$shape" != mixed ] || expected=work
  before=$(wc -l < "$AI_ACCOUNT_LEDGER")
  payload "$HOME/repo-a" | AI_QUOTAS_CONFIG="$HOME/malformed-entry-registry.json" CLAUDE_CONFIG_DIR="$HOME/personal/claude" "$HOOK" >/dev/null
  [ "$(wc -l < "$AI_ACCOUNT_LEDGER")" -eq "$((before+1))" ]
  jq -e --arg label "$expected" '.label==$label and .session_id=="test"' < <(tail -1 "$AI_ACCOUNT_LEDGER") >/dev/null
done
# Invalid whole-registry documents cannot attribute a selected profile.
for shape in empty scalar array multiple; do
  case "$shape" in
    empty) : > "$HOME/whole-registry.json" ;;
    scalar) printf '42\n' > "$HOME/whole-registry.json" ;;
    array) printf '[]\n' > "$HOME/whole-registry.json" ;;
    multiple) { cat "$AI_QUOTAS_CONFIG"; printf '%s\n' '{"accounts":[]}'; } > "$HOME/whole-registry.json" ;;
  esac
  payload "$HOME" | AI_QUOTAS_CONFIG="$HOME/whole-registry.json" CLAUDE_CONFIG_DIR="$HOME/personal/claude" "$HOOK" >/dev/null
  jq -e '.label=="unknown" and .session_id=="test"' < <(tail -1 "$AI_ACCOUNT_LEDGER") >/dev/null
done
# A different spelling of the same filesystem location is not a registered identity.
ln -s "$HOME/personal/claude" "$HOME/alias"
for spelling in "$HOME/alias" "$HOME/personal/./claude" "$HOME/personal/claude/"; do
  payload "$HOME" | CLAUDE_CONFIG_DIR="$spelling" "$HOOK" >/dev/null
  jq -e --arg spelling "$spelling" '.label=="unknown" and .profile_dir==$spelling' < <(tail -1 "$AI_ACCOUNT_LEDGER") >/dev/null
done
# An explicitly registered alias has its own label despite sharing a physical target.
jq --arg alias "$HOME/alias" '.accounts += [{provider:"claude",label:"alias-account",profile_dir:$alias}]' "$AI_QUOTAS_CONFIG" > "$HOME/alias-registry.json"
for spelling in "$HOME/alias" "$HOME/personal/claude"; do
  expected=work; [ "$spelling" != "$HOME/alias" ] || expected=alias-account
  payload "$HOME" | AI_QUOTAS_CONFIG="$HOME/alias-registry.json" CLAUDE_CONFIG_DIR="$spelling" "$HOOK" >/dev/null
  jq -e --arg spelling "$spelling" --arg label "$expected" '.label==$label and .profile_dir==$spelling' < <(tail -1 "$AI_ACCOUNT_LEDGER") >/dev/null
done
# Conservative Unicode spelling handling must not silently rewrite recorded identity.
nfc="$HOME/"$'caf\xc3\xa9'; nfd="$HOME/"$'cafe\xcc\x81'
jq --arg path "$nfc" '.accounts += [{provider:"claude",label:"unicode-account",profile_dir:$path}]' "$AI_QUOTAS_CONFIG" > "$HOME/unicode-registry.json"
for spelling in "$nfc" "$nfd"; do
  expected=unknown; [ "$spelling" != "$nfc" ] || expected=unicode-account
  payload "$HOME" | AI_QUOTAS_CONFIG="$HOME/unicode-registry.json" CLAUDE_CONFIG_DIR="$spelling" "$HOOK" >/dev/null
  jq -e --arg spelling "$spelling" --arg label "$expected" '.label==$label and .profile_dir==$spelling' < <(tail -1 "$AI_ACCOUNT_LEDGER") >/dev/null
done
# Decode TSV transport without dropping a trailing newline or literal backslash.
spelling="$HOME/"$'line\nwith\ttab\\literal\n'
jq --arg path "$spelling" '.accounts += [{provider:"claude",label:"control-path",profile_dir:$path}]' "$AI_QUOTAS_CONFIG" > "$HOME/control-registry.json"
payload "$HOME" | AI_QUOTAS_CONFIG="$HOME/control-registry.json" CLAUDE_CONFIG_DIR="$spelling" "$HOOK" >/dev/null
jq -e --arg path "$spelling" '.label=="control-path" and .profile_dir==$path' < <(tail -1 "$AI_ACCOUNT_LEDGER") >/dev/null
# NUL cannot occur in an OS path and must never collapse to a different identity.
jq --arg path "$HOME/personal/claude" '.accounts=[{provider:"claude",label:"invalid-nul",profile_dir:($path+"\u0000")}]' "$AI_QUOTAS_CONFIG" > "$HOME/nul-registry.json"
payload "$HOME" | AI_QUOTAS_CONFIG="$HOME/nul-registry.json" CLAUDE_CONFIG_DIR="$HOME/personal/claude" "$HOOK" >/dev/null
jq -e '.label=="unknown"' < <(tail -1 "$AI_ACCOUNT_LEDGER") >/dev/null
# Duplicate declared registrations are ambiguous.
jq '.accounts += [.accounts[0]]' "$AI_QUOTAS_CONFIG" > "$HOME/duplicate.json"
payload "$HOME" | AI_QUOTAS_CONFIG="$HOME/duplicate.json" CLAUDE_CONFIG_DIR="$HOME/personal/claude" "$HOOK" >/dev/null
jq -e '.label=="unknown"' < <(tail -1 "$AI_ACCOUNT_LEDGER") >/dev/null
printf broken > "$HOME/broken.json"
[ "$(payload "$HOME" | AI_QUOTAS_CONFIG="$HOME/broken.json" "$HOOK")" = '{}' ]
[ "$(payload "$HOME" | AI_ACCOUNT_LEDGER=/dev/null/ledger "$HOOK")" = '{}' ]
[ "$(payload "$HOME" | PATH=/nonexistent /bin/bash "$HOOK")" = '{}' ]
# Git is optional: keep known session/account fields while repository metadata is null.
mkdir -p "$HOME/no-git-bin"
for tool in jq date chmod; do ln -s "$(command -v "$tool")" "$HOME/no-git-bin/$tool"; done
[ "$(payload "$HOME/repo-a" | PATH="$HOME/no-git-bin" AI_ACCOUNT_LEDGER="$HOME/gitless.jsonl" CLAUDE_CONFIG_DIR="$HOME/personal/claude" "$HOOK")" = '{}' ]
jq -se 'length==1 and .[0].label=="work" and .[0].session_id=="test" and .[0].repo==null and .[0].branch==null and .[0].issue==null and (.[0].ts|test("Z$"))' "$HOME/gitless.jsonl" >/dev/null
# Timestamp serialization is mandatory; a missing/failing date must not append a blank ts.
mkdir -p "$HOME/no-date-bin"
for tool in jq chmod; do ln -s "$(command -v "$tool")" "$HOME/no-date-bin/$tool"; done
[ "$(payload "$HOME/repo-a" | PATH="$HOME/no-date-bin" AI_ACCOUNT_LEDGER="$HOME/dateless.jsonl" CLAUDE_CONFIG_DIR="$HOME/personal/claude" "$HOOK")" = '{}' ]
[ ! -e "$HOME/dateless.jsonl" ]
cat > "$HOME/no-date-bin/date" <<'DATE'
#!/bin/bash
exit 1
DATE
chmod +x "$HOME/no-date-bin/date"
[ "$(payload "$HOME/repo-a" | PATH="$HOME/no-date-bin" AI_ACCOUNT_LEDGER="$HOME/dateless.jsonl" CLAUDE_CONFIG_DIR="$HOME/personal/claude" "$HOOK")" = '{}' ]
[ ! -e "$HOME/dateless.jsonl" ]
# FIFOs and special destinations must fail open without waiting for a reader.
mkfifo "$HOME/ledger-fifo" "$HOME/registry-fifo" "$HOME/work/claude/.claude.json"
python3 - "$HOOK" "$HOME/ledger-fifo" <<'PYTEST'
import json,os,subprocess,sys
result=subprocess.run([sys.argv[1]],input=json.dumps({'cwd':os.environ['HOME']}),text=True,capture_output=True,timeout=2,env=dict(os.environ,AI_ACCOUNT_LEDGER=sys.argv[2]))
assert result.returncode==0 and result.stdout.strip()=='{}'
for overrides in [{'AI_QUOTAS_CONFIG':os.environ['HOME']+'/registry-fifo'}, {'CLAUDE_CONFIG_DIR':os.environ['HOME']+'/work/claude'}]:
 result=subprocess.run([sys.argv[1]],input=json.dumps({'cwd':os.environ['HOME']}),text=True,capture_output=True,timeout=2,env=dict(os.environ,**overrides))
 assert result.returncode==0 and result.stdout.strip()=='{}'
PYTEST
# Malformed email metadata must not reach rows or terminal annotations.
printf '%s\n' '{"oauthAccount":{"emailAddress":"person@example.test?synthetic-secret\n\u001b"}}' > "$HOME/personal/claude/.claude.json"
payload "$HOME" | CLAUDE_CONFIG_DIR="$HOME/personal/claude" "$HOOK" >/dev/null
jq -e '.label=="work" and .account_email==null' < <(tail -1 "$AI_ACCOUNT_LEDGER") >/dev/null
if grep -q synthetic-secret "$AI_ACCOUNT_LEDGER"; then exit 1; fi
# Credential-bearing remote data must never be persisted.
git -C "$HOME/repo-b" remote add origin 'https://synthetic-user:synthetic-secret@github.com/Owner/Repo.git?synthetic-query#synthetic-fragment'
payload "$HOME/repo-b" | "$HOOK" >/dev/null
jq -e '.repo=="repo-b"' < <(tail -1 "$AI_ACCOUNT_LEDGER") >/dev/null
if grep -q synthetic "$AI_ACCOUNT_LEDGER"; then exit 1; fi
# Detached HEAD must remain null.
git -C "$HOME/repo-a" -c user.name=Test -c user.email=test@example.test commit -qm init --allow-empty
git -C "$HOME/repo-a" checkout -q --detach
payload "$HOME/repo-a" | "$HOOK" >/dev/null
jq -e '.branch==null and .issue==null' < <(tail -1 "$AI_ACCOUNT_LEDGER") >/dev/null
# A repository before its first commit still has a real symbolic branch.
git init -q "$HOME/unborn"
git -C "$HOME/unborn" checkout -qb issue-77-new
payload "$HOME/unborn" | "$HOOK" >/dev/null
jq -e '.repo=="unborn" and .branch=="issue-77-new" and .issue=="77"' < <(tail -1 "$AI_ACCOUNT_LEDGER") >/dev/null
# Measure the normal hook, with a generous regression ceiling; print actual timing.
python3 - "$HOOK" "$HOME/repo-b" "$HOME/personal/claude" <<'PY'
import json,os,subprocess,sys,time
samples=[]
for _ in range(5):
 start=time.perf_counter(); subprocess.run([sys.argv[1]],input=json.dumps({'cwd':sys.argv[2],'source':'startup'}),text=True,stdout=subprocess.DEVNULL,check=True,env=dict(os.environ,CLAUDE_CONFIG_DIR=sys.argv[3])); samples.append((time.perf_counter()-start)*1000)
print('hook latency milliseconds:', ', '.join(f'{s:.1f}' for s in samples))
assert max(samples)<1000
# The <200 ms target is checked manually; CI tolerates scheduler contention.
PY
printf 'PASS account session hook\n'
