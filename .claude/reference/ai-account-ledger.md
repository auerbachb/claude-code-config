# Session account ledger

`ai-account-ledger.sh report [--days N] [--provider claude|codex] [--json]`
shows projects by registered account for a rolling UTC window (default 14 days).
Use the standard script resolution order: `~/.claude/skills-worktree/.claude/scripts/`,
`~/.claude/scripts/`, then the current checkout’s `.claude/scripts/`.
A missing ledger is an empty report, not an error.

## Attribution and privacy

The ledger is `${AI_ACCOUNT_LEDGER:-$HOME/.claude/ai-account-ledger.jsonl}`,
created with owner-only permissions (0600). Each row has:

| Field | Provenance |
|---|---|
| `ts` | UTC hook time, or the Codex session metadata timestamp for backfill |
| `provider`, `label` | Claude/Codex and the unique matching registry row, or `unknown` |
| `profile_dir` | Physical selected config directory (unresolvable paths remain literal) |
| `repo` | Lowercase GitHub owner/repo from origin, otherwise live repository basename; null outside Git or for unsupported historical URLs |
| `branch`, `issue` | Captured branch and issue-N token; null for detached/non-repository contexts |
| `session_id` | Runtime session identifier; backfill uses payload.id or payload.session_id |
| `account_email` | null during capture; optional validated email evidence on explicitly imported rows |
| `source`, `capture` | startup/resume/fork with hook, or backfill/backfill |

`${AI_QUOTAS_CONFIG:-$HOME/.claude/ai-quotas.json}` is the registry. Labels are
resolved by provider and **physical stored `profile_dir`**, never by directory
name, nickname, email, credential contents, or auth status. Zero or multiple
matching registrations produce `unknown`. Issue #1850 added repair tools, but
shipping them does not migrate live profiles. Cross-wired folder names are safe
because only the registered paths are used. No credentials are read or changed.

`account_email` is evidence only; the report annotates
Claude email labels that disagree with that evidence (case insensitive), useful
for investigating Issue #1850. Capture deliberately does not open `.claude.json`: extracting an email would require parsing the whole shared configuration, which can contain unrelated secret-bearing settings. It never opens credential stores or infers identity from emails. Optional imported email evidence must be bounded and control-free; it is never used for attribution. No prompts, messages, tool arguments, or
transcript content are persisted. The backfill reads only the first metadata
record of each rollout; it never opens `auth.json`.

## Claude capture

The existing `register-hooks.py` installer installs the SessionStart entry from
`global-settings.json`. It selects `CLAUDE_CONFIG_DIR`, otherwise `~/.claude`.
Only startup/resume/fork add rows; clear/compact are ignored. The hook emits `{}`
and exits zero on failure, without network calls or transcript scans. Its normal
execution target is below 200 ms; scheduler/filesystem delays can exceed that.
Default and desktop sessions need a trustworthy registered config directory;
otherwise they remain `unknown`. There is no reliable retrospective Claude
account split because share-config shares history. Profiles using share-config
receive settings and hooks; independently configured profiles must install them.

## Codex capture and backfill

`ai-quotas-setup.sh ledger-hooks` merges a SessionStart command into each existing
registered Codex profile’s `hooks.json` and the default `~/.codex` when present.
It preserves unrelated hook groups and never edits `config.toml`. The command
binds the explicit profile path because a runtime may omit CODEX_HOME. Direct
hook invocation also supports CODEX_HOME and a sessions/archived_sessions ancestor
of transcript_path, followed by the default profile.

Codex hook support, feature enablement, and trust review are version dependent.
The locally inspected CLI 0.166.0 reports `hooks stable true`; that is capability
evidence, not proof that a particular non-managed hook has been trusted/executed.
[Official OpenAI documentation](https://learn.chatgpt.com/docs/hooks)
requires trust review for non-managed hooks. The installer does not grant trust or
change feature settings. On unsupported/untrusted installations, use backfill:

```
ai-account-ledger.sh backfill-codex [--codex-home DIR] [--dry-run]
```

Without an explicit home it scans registered Codex paths and the default home.
Only `rollout-*.jsonl` under sessions/ and archived_sessions/ are considered.
The first session_meta record supplies ID, original timestamp, cwd and git
metadata. Historical branches/issues always come from that record; today’s branch
is never substituted. If the original URL is absent, cwd may resolve the repository basename only; the current origin and branch are never borrowed for history. Invalid/truncated metadata is counted and skipped. Existing Codex
session IDs (including live hook rows) are loaded once, making sequential reruns
idempotent. Run one backfill at a time; simultaneous backfills are not serialized.
A directory’s current registration is not proof of historical account ownership:
a profile may have been signed into another account. Treat historical labels as
profile provenance, not verified historical identity.

JSON reports contain `window: {start,end,days}`, `accounts` with provider, label,
nickname and `projects: [{repo,sessions,last_ts}]`, `unknown_sessions`, and
`annotations`. Session counts deduplicate nonempty session IDs within each account/project; rows lacking IDs remain individually countable. Text includes counts/last-seen dates; unknown is a separate account
group. Malformed JSONL and rows without usable provider/label/timestamp are skipped.
The report is informational and never gates dispatch or spending.

Cursor capture and an `AI-Account:` commit trailer are follow-ups outside Issue #1885.
