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
# A physical alias matching multiple registrations is ambiguous.
jq '.accounts += [.accounts[0]]' "$AI_QUOTAS_CONFIG" > "$HOME/duplicate.json"
payload "$HOME" | AI_QUOTAS_CONFIG="$HOME/duplicate.json" CLAUDE_CONFIG_DIR="$HOME/personal/claude" "$HOOK" >/dev/null
jq -e '.label=="unknown"' < <(tail -1 "$AI_ACCOUNT_LEDGER") >/dev/null
printf broken > "$HOME/broken.json"
[ "$(payload "$HOME" | AI_QUOTAS_CONFIG="$HOME/broken.json" "$HOOK")" = '{}' ]
[ "$(payload "$HOME" | AI_ACCOUNT_LEDGER=/dev/null/ledger "$HOOK")" = '{}' ]
[ "$(payload "$HOME" | PATH=/nonexistent /bin/bash "$HOOK")" = '{}' ]
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
