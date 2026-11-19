# AI Quota Tracking — account registry (`~/.claude/ai-quotas.json`)

Reference for `/quotas-setup` and `.claude/scripts/ai-quotas-setup.sh` (issue #1666).
Not auto-loaded; read it when working on the quota tools.

Quick links: [Configuration](#config-file) · [Provider credentials](#where-each-provider-keeps-its-credential) · [Report rows](./ai-quotas-reader.md#json-row-shape) · [History](./ai-quotas-history.md#the-history-file) · [Profile recovery](./ai-quotas-setup.md#fresh-profile-reauthentication) · [Browser diagnosis](./ai-quotas-reader.md#browser-failure-diagnostics-issue-1906) · [Antigravity research](./ai-quotas-antigravity.md).

**Display and configuration only.** Nothing in this file — and nothing any tool built on
it produces — may gate dispatch, pause work, downgrade a model, or feed
`credit-budget.sh`, with one exception: `quota-reserve.sh` may pause *autonomous* work on
an account whose provider-reported weekly used-percent reaches the owner's threshold
(§"The one consumer that acts on these readings (#1863)" below; [`quota-reserve.md`](./quota-reserve.md)). That carve-out
is authorized only by `.claude/rules/safety.md` §"Anthropic Quota & Spend Authority",
which stays the authority on its scope. Otherwise quota and spend authority stays with
Anthropic's in-app UI and upstream harness signals. This registry answers "which
accounts exist and can I reach them", nothing more.

**Distinct wallet.** This file governs the owner's **AI coding-assistant subscriptions** —
Claude Max, ChatGPT Pro / Codex, Cursor Ultra — including what continuing past their caps
costs (§"Overage — what continuing costs" in [`ai-quotas-reader.md`](./ai-quotas-reader.md)). `.claude/reference/pricing-matrix.md` is the
separate **review-stack** wallet: CodeRabbit, BugBot, Greptile, CodeAnt. The two are never
mixed, and no price is copied between them — a figure that appears in both files is a
figure that will be updated in one of them and silently stale in the other.

## Topic map

This file is the overview: the registry, the profile layout and where each provider keeps its credential. Everything else lives in one file per topic; edit the file that owns a fact, and do not copy normative text into this one.

- [`ai-quotas-reader.md`](./ai-quotas-reader.md) — the shared reader contract: JSON row shape, statuses, test seams, overage and the cheapest-next hint, the read-outcome ledger, ordered usage sources and browser diagnostics, last-known folder, the FETCHED column, paid usage, resets and top tier, and plan tier.
- [`ai-quotas-claude.md`](./ai-quotas-claude.md) — the Claude reader, its status-line and app-usage readings, and renewing an expired access token.
- [`ai-quotas-codex.md`](./ai-quotas-codex.md) — the Codex reader and the captured Codex HTTP wire format.
- [`ai-quotas-cursor.md`](./ai-quotas-cursor.md) — the Cursor reader on the IDE token, the captured endpoint and the encrypted-token observation route.
- [`ai-quotas-history.md`](./ai-quotas-history.md) — the history file, the daily unattended job, nicknames and the compact table, and burn-rate projection.
- [`ai-quotas-setup.md`](./ai-quotas-setup.md) — exact re-login commands, launchers and shared config, label/path repair, fresh-profile reauthentication, and export/import of the account list.
- [`ai-quotas-antigravity.md`](./ai-quotas-antigravity.md) — Antigravity research notes.

## Why per-account profiles at all

Five prepaid premium subscriptions cost far less than overage on any one of them, so the
working pattern is to drain one account and switch to the next. None of the providers
supports two accounts side by side out of the box: each keeps one credential in one
place. Giving every account its own profile directory — `CLAUDE_CONFIG_DIR` for Claude
Code, `CODEX_HOME` for Codex — is what lets all of them stay logged in at once, and what
lets a later reader borrow each account's live credential in turn. Cursor is the
exception, and unavoidably so: its credential belongs to the Cursor IDE, which holds
exactly one account (#1703).

## Increment boundary

This registry is increment 1 of six (#1666 → #1667 → #1668 → #1669 → #1700 → #1701). It
ends at a registered, validated account list. **No usage figure is read here.** Increment
2 adds `/quotas` and `.claude/scripts/ai-quotas.sh`, which read the config below and
report each account's remaining allowance; increment 3 (#1668) makes the Cursor slot
live — the two-pool reader documented in [`ai-quotas-cursor.md`](./ai-quotas-cursor.md), rebuilt in #1703 on the Cursor
IDE's own token after the browser login proved impossible to seed;
increment 4 (#1669) adds the overage column and the cheapest-next hint; increment 5
(#1700) records every reading to a history file, adds the daily unattended snapshot,
nicknames, and the compact table; increment 6 (#1701) reads that history for a burn rate
and a days-left projection, and **closes the chain**. Keep the schema simple — a reader
that has to guess is a reader that reports the wrong number.

## Config file

- **Path** `~/.claude/ai-quotas.json` (override with `AI_QUOTAS_CONFIG`)
- **Mode** `600`, always — the file is created through a `600` temp file and installed
  by rename, so it is never briefly world-readable.
- **Location rationale** it lives under `~/.claude/`, never in a worktree, per the
  hook-storage rule (runtime state outlives any one worktree).

```json
{
  "schema_version": "1.0",
  "accounts": [
    {
      "provider": "claude",
      "label": "someone@example.com",
      "profile_dir": "/Users/you/.claude/ai-quotas/profiles/someone@example.com/claude",
      "added_at": "2026-09-07T16:40:00Z",
      "credential_ref": { "kind": "macos-keychain", "service": "Claude Code-credentials-1a2b3c4d" }
    }
  ]
}
```

| Field | Required | Meaning |
|-------|----------|---------|
| `schema_version` | yes | `"1.0"`. Compatibility is by **major**: the tool accepts any `1.x` config (keeping its minor and its unknown fields), and **refuses** a different major with exit `5` rather than rewriting a shape it would silently strip. Readers should tolerate unknown fields rather than fail. |
| `accounts[].provider` | yes | `claude`, `codex`, or `cursor`. |
| `accounts[].label` | yes | What the user typed — for these accounts, the subscription email. Unique per provider; it names the profile directory, so it must start with a letter or digit, may then contain letters, digits and `. _ @ + -`, and is capped at 128 characters (no slashes, nothing that could climb out of the profile root). |
| `accounts[].profile_dir` | yes | Absolute path to this account's isolated profile. |
| `accounts[].nickname` | no | Short display name (#1700), set by `add … --nick <name>` or `nick <label> <name>`. `/quotas` shows it in place of the label. Max 32 characters; no tabs, newlines, control characters, or leading/trailing spaces — it is rendered into a tab-separated table, and a tab in it would split the row into columns that no longer line up with their headers. Clearing it (`nick <label> ""`) **deletes the key** rather than storing `""`. Enforced on **read** as well as on write: the reader accepts any compatible `1.x` registry — hand-edited, or written by a future sibling — and a nickname carrying a control character is dropped there too, falling back to the label exactly as an absent one does. |
| `accounts[].added_at` | yes | UTC ISO-8601 registration timestamp. |
| `accounts[].credential_ref` | no | macOS + `claude` only. The **name** of the Keychain item the login created — `{"kind":"macos-keychain","service":"…"}`. A name, never a value. |
| `accounts[].ids` | no | Provider account/org/user IDs where already known: an object limited to `account_id`, `org_id`, `organization_id`, `user_id` (string values, max 64 characters, each exactly a UUID, digits, or a `user-`/`org-`/`acct-` prefixed ID, and never credential-shaped). Carried by `export`/`import` (#2468); nothing in this repo writes it today, so a registry gets it by hand or from an import. |

**No field ever holds a token, cookie, or password.** That is not a convention, it is the
design: every reader borrows the provider tool's own live credential at run time, so
there is nothing here worth stealing.

The invariant the test suite asserts is about **key names**: no key anywhere in the
config matches `token|password|cookie`. The blunter check from the issue's Test Plan —
`grep -iE 'token|password|cookie' ~/.claude/ai-quotas.json` returning nothing — is also
asserted, but it scans the whole file, so a perfectly legitimate label such as
`token@example.com` would trip it. When it does, read the key names before concluding
anything leaked.

The same label may appear under two providers. When it does, `remove` and `relogin`
require the provider as a second argument rather than guessing which row was meant.

## Profile directories

```
~/.claude/ai-quotas/profiles/<label>/claude    # CLAUDE_CONFIG_DIR for that account
~/.claude/ai-quotas/profiles/<label>/codex     # CODEX_HOME for that account
                                               # cursor has NO profile directory —
                                               # the Cursor IDE owns that login (#1703)
~/.claude/ai-quotas/profiles/<label>/.keychain-service-claude   # mode 600; see below
~/.claude/ai-quotas/profiles/.relogin-slots/<label>__<provider> # relogin slot; see below
```

### Relogin slots

`relogin` claims `.relogin-slots/<label>__<provider>` — an empty directory holding a
`pid` file — for the whole run, and refuses (**exit 7**) when another relogin already
holds it. Two relogins for one account must not overlap: both would write the registry
row, and whichever finished last would decide what the account points at.

The slot no longer guards a **profile retirement**. Through #1668 a Cursor relogin moved
the old Chromium profile aside to `<dir>.retired-<timestamp>`, with a rollback trap to
put it back on failure; #1703 removed all of it along with the browser. An IDE token has
no profile to retire and no layering to prevent — signing in again in the IDE simply
replaces it — so the slot's whole job is now refusing the concurrent run.

The slot is a flat key under the profile root rather than a sibling of the profile,
because a sibling would have to be created through the label and provider components —
the ones `ensure_profile_dir` refuses to create through until it has proved on the
physical path that no symlink redirects them out of the root.

A relogin killed hard leaves a marker no one owns. The next run reads the recorded pid,
and a holder it can **prove** is gone (`kill -0` fails) is taken over; a live one, or one
whose pid cannot be read, is refused — guessing "probably dead" is the outcome the slot
exists to prevent. That takeover is itself serialized by a `<slot>.recovering` guard,
which is refused rather than broken: it covers a handful of non-blocking filesystem calls
and nothing else, so there is no slow case to wait out.

Both paths are cleared by hand if a crash ever leaves one behind — the refusal message
names the exact directory to delete once you have confirmed no relogin is running.

The `.keychain-service-<provider>` sidecar holds the **name** of the Keychain item the
provider's login created for that profile — never a value, never a secret. It is written
mode `600` beside the profile (not inside it, so nothing the provider's own tool reads is
disturbed), and it survives `remove`, which is the whole point: see below.

Created mode `700`, along with the parents the tool creates. `remove` deletes the
registry row and **leaves the directory on disk**, printing its path: dropping a row
must never destroy a working login. Delete it by hand if that is what you mean.

## Where each provider keeps its credential

| Provider | Credential artifact | How `list` sees it |
|----------|--------------------|--------------------|
| `claude` (macOS) | Keychain generic password, service `Claude Code-credentials-<suffix>` | `security find-generic-password -s "<service>"` — **never** `-w`, so no value is requested. The service is looked up by the name recorded at login time. |
| `claude` (other) | `<profile_dir>/.credentials.json` | file present and non-empty |
| `codex` | `<profile_dir>/auth.json` | file present and non-empty; if it is absent, `CODEX_HOME=<profile_dir> codex login status` is consulted and a zero exit counts as logged in. Its output is discarded, so no account detail is printed. |
| `cursor` | the **Cursor IDE's own login**, in its state store (`~/Library/Application Support/Cursor/User/globalStorage/state.vscdb`, keys `cursorAuth/accessToken` and `cursorAuth/cachedEmail`; Linux and Windows paths in [`ai-quotas-cursor.md`](./ai-quotas-cursor.md)). No profile directory is created. | `sqlite3 -readonly` asks whether `cursorAuth/accessToken` is a non-empty string and answers with an exit status. **Presence only** — the value is never fetched or printed. A token can be present and expired, so only `/quotas` proves it still works. |

### Keychain services are observed at login

Claude Code appends a suffix to the Keychain service name that is derived from
`CLAUDE_CONFIG_DIR` by an undocumented function. Registration observes names rather
than reimplementing it; the separately verified cycle-repair guard is described
in [layout recovery](./ai-quotas-setup.md#diagnose-and-repair-labelpath-layout-issue-1850).
It lists the `Claude Code-credentials*` service **names** before and after running the
login and records the one that appeared. Guessing the algorithm would fail silently the
first time upstream changed it — and a status probe that silently reports `needs-login`
for a perfectly good account is worse than one that never shipped.

If the recorded item later vanishes (keychain reset, item deleted), `list` reports
`needs-login` and `relogin` records whatever new item the next login creates.

**When no new item appears, the name is recalled, not guessed.** A login against a
profile that already has a Keychain item *rewrites* that item, so the before/after diff
is empty — the ordinary shape of re-registering a label whose profile `remove` left on
disk. The tool then falls back to the `.keychain-service-<provider>` sidecar written
beside the profile at the original login. The sidecar is never trusted on its own: the
status probe still asks the Keychain whether that item exists, so a stale sidecar yields
`needs-login`, never a false `ok`.

A sidecar that cannot be written does **not** fail the `add` — the credential itself is
already verified, and the row is genuine — but it is never silent either: the tool warns
on stderr at the moment the write (or its `chmod 600`) fails. Without that warning, the
cost lands much later and looks unexplained, as a re-add of that same label failing
closed for a reason nothing on screen accounts for.

**An ambiguous snapshot is refused, not guessed.** If two logins overlap, more than one
item can appear between one run's snapshots. Picking the first would bind an account to
another account's credential — a wrong answer that looks exactly like a right one — so
the tool exits `1`, records nothing, and asks for the login to be re-run on its own. The
alternative (a dedicated keychain lock held across the login) was declined: it would hold
a lock for the length of an unbounded interactive flow, well past the 120s staleness
ceiling that would then let another writer break it mid-login anyway.

## Statuses

| Status | Meaning |
|--------|---------|
| `ok` | The provider's own credential artifact is present for that profile. |
| `needs-login` | Credential presence could not be verified. Check the note, or `detail` in JSON. |

Use `relogin` when the note identifies a missing credential or a signed-out IDE. A
missing probe tool or unreadable store must be resolved before retrying sign-in.

`--no-login` skips the login during registration. A reserved slot can still report `ok`
if the registered profile or Cursor IDE already holds a credential.

On a readable config `list` always exits `0` whatever the statuses say — it is a report,
not a gate, and a `needs-login` row is not a failure. The one way `list` exits non-zero
is exit `5`, when the config itself cannot be read (missing `jq`, unparseable file, or a
different schema major); that is a broken tool, not a verdict about an account.

## Helper contract

Full flags and exit codes: `ai-quotas-setup.sh --help`. Summary:

| Exit | Meaning |
|------|---------|
| 0 | Action completed (`list` exits 0 for any account status, on a readable config). |
| 1 | The login ran but left no visible credential; **nothing was recorded**. |
| 3 | Usage error — bad action/provider/label, duplicate pair, or an ambiguous label. |
| 4 | No account matches that label. |
| 5 | Dependency or write failure (`jq` missing, config unreadable, unparseable, or written by a different schema major). Also a `repair-layout` preflight refusal: missing/shared sources, collisions, symlinks, unsupported credential backing or an interrupted repair; these refusals leave the registry and profiles unchanged. |
| 6 | The provider's login CLI was not found — for `cursor`, `sqlite3`, which is what reads the IDE state store; the manual command is printed. |
| 7 | A registry write or relogin was blocked by contention, or the profile changed during login. This run did not commit a registry update. An already-completed login can have written profile credentials; check the helper's exact message before retrying. |
| 8 | `doctor` found layout problems; diagnostic only, never a dispatch gate. |
| 9 | Incomplete `repair-layout` rollback; preserve `.layout-repair/` for manual recovery. |

Config writes go through the shared `state-lock.sh` advisory lock and
`state_lock_commit`, so a concurrent `add` cannot lose the other's row.

**Test seams.** `AI_QUOTAS_CONFIG`, `AI_QUOTAS_PROFILE_ROOT`, `AI_QUOTAS_CLAUDE_BIN`,
`AI_QUOTAS_CODEX_BIN`, `AI_QUOTAS_SECURITY_BIN`, `AI_QUOTAS_SQLITE3_BIN`,
`AI_QUOTAS_CURSOR_STATE_DB`, and `AI_QUOTAS_PLATFORM` exist so
`.claude/scripts/tests/ai-quotas-setup.test.sh` can exercise every path — including the
macOS Keychain probe — against stubs, without touching a real login, keychain, or
account. They are not meant for normal use. `AI_QUOTAS_LAUNCHERS_FILE`,
`AI_QUOTAS_PRIMARY_CLAUDE_DIR`, `AI_QUOTAS_PRIMARY_CLAUDE_JSON`, and
`AI_QUOTAS_PRIMARY_CODEX_HOME` (#1851) do the same for `launchers` and `share-config` in
`ai-quotas-share.test.sh`; their defaults derive from `HOME`, which the suite redirects.

## Symlink

Per `.claude/rules/skill-symlinks.md`, `/quotas-setup` and `/quotas` are symlinked into
`~/.claude/skills/` through the skills worktree **after** their PRs merge — never before,
and never directly to the root repo.

## The one consumer that acts on these readings (#1863)

The table and projections are display-only. `quota-reserve.sh` is the single exception: it reads the same provider-reported weekly used-percent and, at the owner's threshold (95% default), pauses *autonomous* work on that account, never the owner's own turns. It is an owner-approved carve-out in `.claude/rules/safety.md`, evaluated only against the provider's reading and failing open on anything unreadable or stale. Mechanism, what is blocked, and what is deliberately not covered: [`quota-reserve.md`](./quota-reserve.md).

## Session attribution

For account × project history, see [ai-account-ledger.md](ai-account-ledger.md). The dedicated ledger report is separate from live quota output.
