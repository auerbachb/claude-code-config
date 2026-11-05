#!/bin/bash
# catalog: token-measurement — Verify metadata-only Codex backfill, idempotency, historical branch provenance, and rolling account/project reports.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
CLI="$ROOT/.claude/scripts/ai-account-ledger.sh"
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
trap cleanup_fixture EXIT; export AI_ACCOUNT_LEDGER="$HOME/.claude/ai-account-ledger.jsonl"
mkdir -p "$HOME/.claude" "$HOME/profile/sessions/2026/11/01" "$HOME/profile/archived_sessions" "$HOME/repo"
git init -q "$HOME/repo"; git -C "$HOME/repo" checkout -qb issue-999-today
export AI_QUOTAS_CONFIG="$HOME/.claude/ai-quotas.json"
jq -n --arg p "$HOME/profile" '{accounts:[{provider:"codex",label:"work",nickname:"Office",profile_dir:$p}]}' > "$AI_QUOTAS_CONFIG"
# Deliberately contradictory live branch and historical branch.
jq -cn --arg cwd "$HOME/repo" '{type:"session_meta",payload:{id:"old",timestamp:"2026-11-01T01:02:03Z",cwd:$cwd,git:{branch:"issue-1885-historical",repository_url:"git@github.com:Owner/Repo.git"}}}' > "$HOME/profile/sessions/2026/11/01/rollout-old.jsonl"
printf '%s\n' '{"type":"event_msg","payload":{"content":"SENTINEL: NEVER READ OR STORE"}}' >> "$HOME/profile/sessions/2026/11/01/rollout-old.jsonl"
jq -cn '{type:"session_meta",payload:{id:"archive",timestamp:"2026-11-01T02:00:00Z",git:{repository_url:"https://github.com/Owner/Other.git"}}}' > "$HOME/profile/archived_sessions/rollout-archive.jsonl"
printf broken > "$HOME/profile/archived_sessions/rollout-broken.jsonl"
cp "$HOME/profile/sessions/2026/11/01/rollout-old.jsonl" "$HOME/profile/archived_sessions/rollout-duplicate.jsonl"
"$CLI" backfill-codex --dry-run
[ ! -e "$AI_ACCOUNT_LEDGER" ]
"$CLI" backfill-codex
jq -se 'length==2 and all(.label=="work" and .capture=="backfill") and any(.session_id=="old" and .ts=="2026-11-01T01:02:03Z" and .branch=="issue-1885-historical" and .issue=="1885" and .repo=="owner/repo") and any(.session_id=="archive" and .branch==null)' "$AI_ACCOUNT_LEDGER" >/dev/null
if grep -q SENTINEL "$AI_ACCOUNT_LEDGER"; then exit 1; fi
"$CLI" backfill-codex
[ "$(wc -l < "$AI_ACCOUNT_LEDGER" | tr -d ' ')" = 2 ]
# Existing hook captures suppress backfill duplicates.
printf '42\n' > "$HOME/hook-rows.jsonl"
jq -c '.capture="hook"' "$AI_ACCOUNT_LEDGER" >> "$HOME/hook-rows.jsonl"
jq -nc 'range(0;10000) | {provider:"codex",session_id:("noise-" + tostring)}' >> "$HOME/hook-rows.jsonl"
AI_ACCOUNT_LEDGER="$HOME/hook-rows.jsonl" "$CLI" backfill-codex
[ "$(wc -l < "$HOME/hook-rows.jsonl" | tr -d ' ')" = 10003 ]
# Present non-GitHub history must never adopt the current remote after a move.
git -C "$HOME/repo" remote add origin https://github.com/Current/Moved.git
mkdir -p "$HOME/nonnewline/sessions"
jq -cjn --arg cwd "$HOME/repo" '{type:"session_meta",payload:{id:"moved",timestamp:"2026-11-01T01:02:03Z",cwd:$cwd,git:{branch:"issue-17-old",repository_url:"https://historical.example/Old/Repo.git"}}}' > "$HOME/nonnewline/sessions/rollout-moved.jsonl"
AI_ACCOUNT_LEDGER="$HOME/moved.jsonl" "$CLI" backfill-codex --codex-home "$HOME/nonnewline"
jq -se 'length==1 and .[0].repo==null and .[0].branch=="issue-17-old" and .[0].issue=="17"' "$HOME/moved.jsonl" >/dev/null
# Without a historical URL, use only the repository basename, never its current origin.
jq -cn --arg cwd "$HOME/repo" '{type:"session_meta",payload:{id:"no-url",timestamp:"2026-11-01T01:02:03Z",cwd:$cwd,git:{branch:"issue-18-old"}}}' > "$HOME/nonnewline/sessions/rollout-no-url.jsonl"
AI_ACCOUNT_LEDGER="$HOME/moved.jsonl" "$CLI" backfill-codex --codex-home "$HOME/nonnewline"
jq -se 'length==2 and any(.session_id=="no-url" and .repo=="repo" and .branch=="issue-18-old")' "$HOME/moved.jsonl" >/dev/null
# Report fixtures are relative to now so the rolling cutoff stays meaningful.
jq -nrc 'now as $now | [
 {ts:(($now-86400)|todateiso8601),provider:"codex",label:"work",repo:"a"},
 {ts:(($now-86400)|todateiso8601),provider:"codex",label:"work",repo:"a"},
 {ts:(($now-86400)|todateiso8601),provider:"codex",label:"work",repo:"a",session_id:"resumed"},
 {ts:(($now-3600)|todateiso8601),provider:"codex",label:"work",repo:"a",session_id:"resumed"},
 {ts:(($now-86400)|todateiso8601),provider:"claude",label:"unknown",repo:null,session_id:"unknown-resume"},
 {ts:(($now-3600)|todateiso8601),provider:"claude",label:"unknown",repo:null,session_id:"unknown-resume"},
 {ts:(($now-15*86400)|todateiso8601),provider:"codex",label:"work",repo:"old"},
 {ts:(($now-86400)|todateiso8601),provider:"claude",label:"unknown",repo:null},
 {ts:(($now-86400)|todateiso8601),provider:"claude",label:"safe-test",repo:"unsafe\u001b]0;injected\u0007\n\u007f"},
 {ts:(($now-86400)|todateiso8601),provider:"claude",label:"imported@example.test",account_email:"other@example.test\n",repo:"invalid-import"},
 {ts:(($now-86400)|todateiso8601),provider:"claude",label:"wrong@example.test",account_email:"right@example.test",repo:"b"}
][]' > "$AI_ACCOUNT_LEDGER"
printf 'broken\n{}\n' >> "$AI_ACCOUNT_LEDGER"
"$CLI" report --json | jq -e '.window.days==14 and .unknown_sessions==2 and (.annotations|length)==1 and any(.accounts[]; .provider=="codex" and .nickname=="Office" and .projects==[{repo:"a",sessions:3,last_ts:.projects[0].last_ts}])' >/dev/null
"$CLI" report --days 30 --provider codex --json | jq -e '(.accounts|length)==1 and (.accounts[0].projects|length)==2' >/dev/null
report_text=$("$CLI" report)
grep -Fq 'codex work (Office): a ×3' <<< "$report_text"
python3 - "$CLI" <<'DISPLAY'
import json,subprocess,sys
text=subprocess.check_output([sys.argv[1],'report'],text=True)
assert not any(ord(c)<32 and c!='\n' or ord(c)==127 for c in text)
raw=subprocess.check_output([sys.argv[1],'report','--json'],text=True)
assert '\x1b' not in raw and '\x7f' not in raw
repo=next(a for a in json.loads(raw)['accounts'] if a['label']=='safe-test')['projects'][0]['repo']
assert repo=='unsafe\x1b]0;injected\x07\n\x7f'
DISPLAY
AI_ACCOUNT_LEDGER="$HOME/missing" "$CLI" report --json | jq -e '.accounts==[] and .unknown_sessions==0' >/dev/null
# Hook installation preserves other hooks, is idempotent, and never touches config.toml.
printf 'original config\n' > "$HOME/profile/config.toml"
printf '%s\n' '{"hooks":{"Stop":[{"hooks":[{"command":"other"}]}]}}' > "$HOME/profile/hooks.json"
"$ROOT/.claude/scripts/ai-quotas-setup.sh" ledger-hooks
cp "$HOME/profile/hooks.json" "$HOME/before-hooks.json"
"$ROOT/.claude/scripts/ai-quotas-setup.sh" ledger-hooks
cmp "$HOME/before-hooks.json" "$HOME/profile/hooks.json"
jq -e '.hooks.Stop[0].hooks[0].command=="other" and (.hooks.SessionStart|length)==1' "$HOME/profile/hooks.json" >/dev/null
[ "$(cat "$HOME/profile/config.toml")" = 'original config' ]
# An existing startup-only command must gain resume/fork coverage without duplicates.
jq '.hooks.SessionStart[0].matcher="startup"' "$HOME/profile/hooks.json" > "$HOME/startup-only.json"
cp "$HOME/startup-only.json" "$HOME/profile/hooks.json"
"$CLI" install-codex-hooks
jq -e '(.hooks.SessionStart|length)==2 and .hooks.SessionStart[1].matcher=="resume|fork" and .hooks.Stop[0].hooks[0].command=="other"' "$HOME/profile/hooks.json" >/dev/null
cp "$HOME/profile/hooks.json" "$HOME/covered-hooks.json"
"$CLI" install-codex-hooks
cmp "$HOME/covered-hooks.json" "$HOME/profile/hooks.json"
# Invalid structural types must not be normalized into overwritten configuration.
for shape in '{"hooks":false}' '{"hooks":{"SessionStart":false}}'; do
  printf '%s\n' "$shape" > "$HOME/profile/hooks.json"
  cp "$HOME/profile/hooks.json" "$HOME/invalid-shape.json"
  if "$CLI" install-codex-hooks; then exit 1; fi
  cmp "$HOME/invalid-shape.json" "$HOME/profile/hooks.json"
done
# Empty or multi-document configuration must be rejected without publication.
printf '{}\n{}\n' > "$HOME/profile/hooks.json"
cp "$HOME/profile/hooks.json" "$HOME/multi-hooks.json"
if "$CLI" install-codex-hooks; then exit 1; fi
cmp "$HOME/multi-hooks.json" "$HOME/profile/hooks.json"
: > "$HOME/profile/hooks.json"
if "$CLI" install-codex-hooks; then exit 1; fi
[ ! -s "$HOME/profile/hooks.json" ]
# Invalid configuration must remain unchanged and leave no temporary artifact.
printf 'broken\n' > "$HOME/profile/hooks.json"
if "$CLI" install-codex-hooks; then exit 1; fi
[ "$(cat "$HOME/profile/hooks.json")" = broken ]
[ -z "$(find "$HOME/profile" -name '.ledger-hooks.*' -print)" ]
# Both public setup and direct installer refuse malformed registries before any writes.
mkdir -p "$HOME/.codex"
printf '{"hooks":{"Stop":[]}}\n' > "$HOME/.codex/hooks.json"
cp "$HOME/.codex/hooks.json" "$HOME/default-hooks-before.json"
for invalid in broken '42' '{"accounts":false}' '{"accounts":[]}{}' '{"accounts":[{"provider":"codex","label":"bad","profile_dir":null}]}'; do
  printf '%s\n' "$invalid" > "$HOME/invalid-registry.json"
  if AI_QUOTAS_CONFIG="$HOME/invalid-registry.json" "$CLI" install-codex-hooks; then exit 1; fi
  if AI_QUOTAS_CONFIG="$HOME/invalid-registry.json" "$ROOT/.claude/scripts/ai-quotas-setup.sh" ledger-hooks; then exit 1; fi
  cmp "$HOME/default-hooks-before.json" "$HOME/.codex/hooks.json"
done
# Special-file inputs fail promptly instead of waiting for a FIFO writer.
mkfifo "$HOME/fifo-ledger" "$HOME/fifo-registry"
python3 - "$CLI" "$HOME/profile" <<'PYTEST'
import os,subprocess,sys
cli,profile=sys.argv[1:]; home=os.environ['HOME']
for action in ['report','backfill-codex']:
 result=subprocess.run([cli,action],env=dict(os.environ,AI_ACCOUNT_LEDGER=home+'/fifo-ledger'),text=True,capture_output=True,timeout=5)
 assert result.returncode==5 and 'regular file' in result.stderr
# A special registry supplies no account mapping, while valid metadata stays capturable.
result=subprocess.run([cli,'backfill-codex','--codex-home',profile],env=dict(os.environ,AI_QUOTAS_CONFIG=home+'/fifo-registry',AI_ACCOUNT_LEDGER=home+'/fifo-registry-rows.jsonl'),text=True,capture_output=True,timeout=5)
assert result.returncode==0
import json
assert all(json.loads(line)['label']=='unknown' for line in open(home+'/fifo-registry-rows.jsonl'))
os.unlink(profile+'/hooks.json'); os.mkfifo(profile+'/hooks.json')
result=subprocess.run([cli,'install-codex-hooks'],text=True,capture_output=True,timeout=5)
assert result.returncode==5 and 'non-regular' in result.stderr
# The public entry point must reject a FIFO before its own read_config/cat.
import pathlib
setup=str(pathlib.Path(cli).with_name('ai-quotas-setup.sh'))
result=subprocess.run([setup,'ledger-hooks'],env=dict(os.environ,AI_QUOTAS_CONFIG=home+'/fifo-registry'),text=True,capture_output=True,timeout=5)
assert result.returncode==5 and 'regular file' in result.stderr
PYTEST
# Profile enumeration and command quoting preserve newlines, tabs and backslashes.
control_profile="$HOME/"$'profile\nwith\ttab\\slash\n'
mkdir -p "$control_profile/sessions"
jq -n --arg path "$control_profile" '{accounts:[{provider:"codex",label:"control-profile",profile_dir:$path}]}' > "$HOME/control-registry.json"
jq -cn '{type:"session_meta",payload:{id:"control-profile",timestamp:"2026-11-01T01:02:03Z"}}' > "$control_profile/sessions/rollout-control.jsonl"
AI_QUOTAS_CONFIG="$HOME/control-registry.json" AI_ACCOUNT_LEDGER="$HOME/control-ledger.jsonl" "$CLI" backfill-codex
jq -se --arg path "$control_profile" 'length==1 and .[0].label=="control-profile" and .[0].profile_dir==$path' "$HOME/control-ledger.jsonl" >/dev/null
AI_QUOTAS_CONFIG="$HOME/control-registry.json" "$CLI" install-codex-hooks >/dev/null
command=$(jq -r '.hooks.SessionStart[0].hooks[0].command' "$control_profile/hooks.json")
printf '%s\n' '{"session_id":"control-hook"}' | AI_QUOTAS_CONFIG="$HOME/control-registry.json" AI_ACCOUNT_LEDGER="$HOME/control-ledger.jsonl" bash -c "$command"
jq -se --arg path "$control_profile" 'length==2 and all(.label=="control-profile" and .profile_dir==$path)' "$HOME/control-ledger.jsonl" >/dev/null
# Historical cwd must preserve its actual filesystem spelling, not target a stripped repo.
control_cwd="$HOME/"$'project\nwith\ttab\rand\037separator\\literal\n'
stripped_cwd=$(jq -nr --arg path "$control_cwd" '$path|gsub("[\u001f\t\r\n]";"")')
git init -q "$control_cwd"
git init -q "$stripped_cwd"
jq -cn --arg cwd "$control_cwd" '{type:"session_meta",payload:{id:"control-cwd",timestamp:"2026-11-01T01:02:03Z",cwd:$cwd,git:{branch:"historical-control"}}}' > "$control_profile/sessions/rollout-cwd.jsonl"
AI_QUOTAS_CONFIG="$HOME/control-registry.json" AI_ACCOUNT_LEDGER="$HOME/cwd-ledger.jsonl" "$CLI" backfill-codex
jq -se 'any(.session_id=="control-cwd" and .repo==null and .branch=="historical-control")' "$HOME/cwd-ledger.jsonl" >/dev/null
# A partial find result must warn, return nonzero, and clean its owned inventory.
mkdir -p "$HOME/failing-bin" "$HOME/scan-tmp"
export ACCOUNT_TEST_FIND
ACCOUNT_TEST_FIND=$(command -v find)
cat > "$HOME/failing-bin/find" <<'FIND'
#!/bin/bash
"$ACCOUNT_TEST_FIND" "$@"
exit 1
FIND
chmod +x "$HOME/failing-bin/find"
status=0
PATH="$HOME/failing-bin:$PATH" TMPDIR="$HOME/scan-tmp" AI_QUOTAS_CONFIG="$HOME/control-registry.json" AI_ACCOUNT_LEDGER="$HOME/partial-ledger.jsonl" "$CLI" backfill-codex > "$HOME/partial.out" 2> "$HOME/partial.err" || status=$?
[ "$status" = 5 ]
grep -Fq 'warning: Codex rollout scan failed; backfill may be incomplete' "$HOME/partial.err"
jq -se 'length==2 and all(.label=="control-profile")' "$HOME/partial-ledger.jsonl" >/dev/null
[ -z "$(find "$HOME/scan-tmp" -type f -print)" ]
printf 'PASS account ledger\n'
