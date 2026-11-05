#!/bin/bash
# catalog: token-measurement — Verify metadata-only Codex backfill, idempotency, historical branch provenance, and rolling account/project reports.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
CLI="$ROOT/.claude/scripts/ai-account-ledger.sh"
HOME="$(mktemp -d)"; export HOME; export AI_ACCOUNT_LEDGER="$HOME/.claude/ai-account-ledger.jsonl"
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
 {ts:(($now-86400)|todateiso8601),provider:"claude",label:"imported@example.test",account_email:"other@example.test\n",repo:"invalid-import"},
 {ts:(($now-86400)|todateiso8601),provider:"claude",label:"wrong@example.test",account_email:"right@example.test",repo:"b"}
][]' > "$AI_ACCOUNT_LEDGER"
printf 'broken\n{}\n' >> "$AI_ACCOUNT_LEDGER"
"$CLI" report --json | jq -e '.window.days==14 and .unknown_sessions==2 and (.annotations|length)==1 and any(.accounts[]; .provider=="codex" and .nickname=="Office" and .projects==[{repo:"a",sessions:3,last_ts:.projects[0].last_ts}])' >/dev/null
"$CLI" report --days 30 --provider codex --json | jq -e '(.accounts|length)==1 and (.accounts[0].projects|length)==2' >/dev/null
report_text=$("$CLI" report)
grep -Fq 'codex work (Office): a ×3' <<< "$report_text"
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
printf 'PASS account ledger\n'
